;;; macros-k8s — a Kubernetes dashboard for the macros editor, in Steel.
;;;
;;; A magit-style porcelain for `kubectl`. It sits on the same editor primitives
;;; magit.scm / macros-jj use — the Rust core knows nothing about k8s:
;;;   * `call-process` / `call-process-full` — run kubectl, capture stdout/stderr
;;;   * lib-section (`section-open`/`section-line`/`section-render`) — foldable,
;;;     navigable read-only status buffer with persistent fold state
;;;   * `render-buffer` / `render-buffer-quiet` — draw detail buffers
;;;   * `make-terminal` + `split-window-below` — `s` opens a pod shell in a pane
;;;   * `run-with-timer` — optional auto-refresh polling
;;;   * `completing-read` / `read-string` / `y-or-n-p` — prompts + confirms
;;;
;;; Conventions (matching macros-jj / macros-web-reader):
;;;   * public commands are `k8s-…`
;;;   * private helpers are `k8s--…` (double dash)
;;;   * ALL mutable runtime state lives in ONE hash, `k8s-state`, reached through
;;;     `k8s--st` / `k8s--st!`, so the package adds only a handful of globals.
;;;
;;; kubectl output is parsed as columnar text (no JSON parser in Steel): each
;;; `get` keeps its header row (dim) and one colored row per resource. Pods are
;;; grouped by owning workload and nodes by node pool (both without JSON — see
;;; k8s--pod-group-map / k8s--node-group-map); deployments and services are flat.
;;;
;;;   M-x k8s-dashboard     open the dashboard for the current context (bind it
;;;   yourself if you want a key — this package adds no global bindings).
;;;
;;; Self-contained apart from lib-section + lib-transient (both ship with the
;;; editor, and sort before this file). `kubectl` must be on PATH — override with
;;; the *k8s-command* default (see the README config caveat).

;; ── configuration ────────────────────────────────────────────────────────────
(define *k8s-command* "kubectl")     ; the kubectl executable
(define *k8s-log-tail* 500)          ; lines fetched by the logs (l) command
(define *k8s-auto-refresh-ms* 5000)  ; poll interval when auto-refresh is on

;; The shell `s` runs inside a pod (via `kubectl exec -it`). Configured through
;; the editor's OPTION store, not a Scheme var — a plain `(define *k8s-shell* …)`
;; before load is clobbered by the package's own define, and a loaded file's own
;; vars can't be set! from init.scm (each file is its own Steel unit). `set-option`
;; writes to the Rust-side option map, so this reads cleanly regardless of load
;; order:  (set-option "k8s-shell" "/bin/sh")  in init.scm.
(define (k8s--shell)
  (let ((v (get-option "k8s-shell")))
    (if (and (string? v) (not (equal? v ""))) v "/bin/bash")))
;; Node label to group Nodes by, via the option store (read by k8s--node-group-label):
;;   (set-option "k8s-node-group-label" "topology.kubernetes.io/zone")
;; Unset / "" = auto-detect the cloud node-pool label (EKS / GKE / Karpenter /
;; AKS). Nodes stay flat unless grouping yields 2+ groups.

;; ── faces ─────────────────────────────────────────────────────────────────────
;; User-overridable: redefine any of these in init.scm. Re-apply after a
;; load-theme, which wipes the palette (see the load-theme-resets-palette note).
(set-face "k8s-header"  "#66d9ef")   ; the context / namespace line
(set-face "k8s-section" "#a6e22e")   ; section headings
(set-face "k8s-ok"      "#a6e22e")   ; Running / Ready / N/N
(set-face "k8s-warn"    "#e6db74")   ; Pending / ContainerCreating / NotReady / warnings
(set-face "k8s-err"     "#f92672")   ; CrashLoopBackOff / Error / Failed / OOMKilled
(set-face "k8s-dim"     "#888888")   ; header rows, hints, empty notes

;; ── state ─────────────────────────────────────────────────────────────────────
(define k8s-state
  (hash
   'context     ""    ; current kube context (resolved each refresh)
   'namespace   "default"
   'ns-resolved #f    ; have we read the context's default namespace yet?
   'all-ns      #f    ; show resources across ALL namespaces (kubectl -A)?
   'linemap     '()   ; (line kind name ns) — resource on each rendered line
   'auto        #f    ; auto-refresh enabled?
   'timer-armed #f    ; is a poll timer currently scheduled?
   'confirm     #f    ; pending destructive-op closure (y-or-n-p)
   ))
(define (k8s--st key) (hash-try-get k8s-state key))
(define (k8s--st! key val) (set! k8s-state (hash-insert k8s-state key val)))

;; ── small helpers ─────────────────────────────────────────────────────────────
;; Non-empty lines of a string.
(define (k8s--lines s)
  (filter (lambda (l) (not (equal? l ""))) (split-many s "\n")))
;; Whitespace-separated fields of a kubectl row (columns are space-padded).
(define (k8s--fields row)
  (filter (lambda (s) (not (equal? s ""))) (split-many row " ")))
(define (k8s--nth-or lst i default)
  (if (< i (length lst)) (nth lst i) default))
(define (k8s--blank? s) (equal? (trim-end s) ""))
;; First n elements of a list.
(define (k8s--take lst n)
  (if (or (= n 0) (null? lst)) '() (cons (car lst) (k8s--take (cdr lst) (- n 1)))))

;; ── kubectl plumbing ──────────────────────────────────────────────────────────
(define (k8s--run args) (call-process *k8s-command* args))
(define (k8s--run-full args) (call-process-full *k8s-command* args ""))
;; kubectl namespace flag for a namespaced GET: `-A` in all-namespaces mode, else
;; `-n <ns>`. Cluster-scoped kinds (nodes) pass namespaced?=#f and get nothing.
(define (k8s--get-ns-args namespaced?)
  (cond ((not namespaced?) '())
        ((k8s--st 'all-ns)  (list "--all-namespaces"))
        (else               (list "-n" (k8s--st 'namespace)))))
;; Namespace flag for an ACTION on a specific resource (its own ns, from the
;; line record) — nodes are cluster-scoped.
(define (k8s--ns-args-for r)
  (if (equal? (nth r 1) "node") '() (list "-n" (nth r 3))))

(define (k8s--resolve-context!)
  (k8s--st! 'context (trim-end (k8s--run (list "config" "current-context")))))
(define (k8s--resolve-namespace!)
  (let ((n (trim-end (k8s--run (list "config" "view" "--minify"
                                     "--output" "jsonpath={..namespace}")))))
    (k8s--st! 'namespace (if (equal? n "") "default" n))))

;; ── status colors ─────────────────────────────────────────────────────────────
(define (k8s--errorish? s)
  (or (string-contains? s "Error") (string-contains? s "CrashLoop")
      (string-contains? s "BackOff") (string-contains? s "OOM")
      (string-contains? s "Evicted") (string-contains? s "Failed")
      (string-contains? s "ImagePull") (string-contains? s "InvalidImageName")
      (string-contains? s "NotReady")))
;; Pod phase / STATUS column.
(define (k8s--phase-face s)
  (cond ((member s (list "Running" "Completed" "Succeeded")) "k8s-ok")
        ((k8s--errorish? s) "k8s-err")
        ((member s (list "Pending" "ContainerCreating" "PodInitializing"
                         "Terminating")) "k8s-warn")
        (else "k8s-dim")))
;; Node STATUS column.
(define (k8s--node-face s)
  (cond ((equal? s "Ready") "k8s-ok")
        ((k8s--errorish? s) "k8s-err")
        (else "k8s-warn")))
;; A "ready/desired" ratio like 3/3 (deployments).
(define (k8s--ratio-face s)
  (let ((p (split-many s "/")))
    (if (and (= (length p) 2) (equal? (car p) (cadr p))) "k8s-ok" "k8s-warn")))
;; HPA TARGETS column, e.g. "45%/80%" or "<unknown>/50%" — red when it can't read
;; metrics (the FailedGetResourceMetric case), else ok.
(define (k8s--hpa-face s)
  (if (string-contains? s "unknown") "k8s-err" "k8s-ok"))

;; Whole-line face for a resource row, dispatched by kind on its status string.
(define (k8s--status-face kind s)
  (cond ((equal? kind "pod")        (k8s--phase-face s))
        ((equal? kind "deployment") (k8s--ratio-face s))
        ((equal? kind "node")       (k8s--node-face s))
        ((equal? kind "hpa")        (k8s--hpa-face s))
        (else                       "k8s-dim")))
;; The most severe face in a set (for a group heading summarizing its pods).
(define (k8s--worst-face faces)
  (cond ((member "k8s-err" faces)  "k8s-err")
        ((member "k8s-warn" faces) "k8s-warn")
        ((member "k8s-ok" faces)   "k8s-ok")
        (else                      "k8s-dim")))

;; ── pod grouping (by owning workload) ─────────────────────────────────────────
;; Distinct list of `lst`, first-seen order preserved.
(define (k8s--uniq lst)
  (let loop ((l lst) (seen '()) (acc '()))
    (cond ((null? l) (reverse acc))
          ((member (car l) seen) (loop (cdr l) seen acc))
          (else (loop (cdr l) (cons (car l) seen) (cons (car l) acc))))))
;; Drop the last `-`-separated segment (a ReplicaSet's name is
;; "<deployment>-<hash>", so this recovers the Deployment).
(define (k8s--strip-last-segment s)
  (let ((parts (split-many s "-")))
    (if (> (length parts) 1)
        (string-join (k8s--take parts (- (length parts) 1)) "-")
        s)))
;; The group a pod belongs to, from its ownerReference. Pods of a Deployment are
;; owned by a ReplicaSet — collapse that to the Deployment; StatefulSet /
;; DaemonSet / Job own their pods directly; unowned pods pool under one heading.
(define (k8s--group-of kind owner)
  (cond ((or (equal? owner "<none>") (equal? owner "")) "(no controller)")
        ((equal? kind "ReplicaSet") (k8s--strip-last-segment owner))
        (else owner)))
;; "ns/pod-name" -> group, from a custom-columns query over ownerReferences (no
;; JSON parser needed; the -o wide rows carry the display columns, this the group).
(define (k8s--pod-group-map)
  (let* ((all  (k8s--st 'all-ns))
         (cols (string-append (if all "NS:.metadata.namespace," "")
                              "NAME:.metadata.name,"
                              "K:.metadata.ownerReferences[0].kind,"
                              "O:.metadata.ownerReferences[0].name"))
         (out  (k8s--run (append (list "get" "pods" "-o" (string-append "custom-columns=" cols)
                                       "--no-headers")
                                 (k8s--get-ns-args #t)))))
    (map (lambda (ln)
           (let* ((f (k8s--fields ln))
                  (ns    (if all (k8s--nth-or f 0 "") (k8s--st 'namespace)))
                  (name  (k8s--nth-or f (if all 1 0) ""))
                  (kind  (k8s--nth-or f (if all 2 1) ""))
                  (owner (k8s--nth-or f (if all 3 2) "")))
             (cons (string-append ns "/" name) (k8s--group-of kind owner))))
         (k8s--lines out))))

;; ── node grouping (by node pool) ──────────────────────────────────────────────
;; Drop the first n elements.
(define (k8s--drop lst n)
  (if (or (= n 0) (null? lst)) lst (k8s--drop (cdr lst) (- n 1))))
(define (k8s--last-n lst n)
  (let ((len (length lst))) (if (>= n len) lst (k8s--drop lst (- len n)))))
;; First non-empty / non-"<none>" value, else "(no pool)".
(define (k8s--first-present vals)
  (cond ((null? vals) "(no pool)")
        ((and (not (equal? (car vals) "<none>")) (not (equal? (car vals) "")))
         (car vals))
        (else (k8s--first-present (cdr vals)))))
;; Configured node-pool label (option store, "" = auto-detect). See k8s--shell
;; for why config lives in the option store rather than a Scheme var.
(define (k8s--node-group-label)
  (let ((v (get-option "k8s-node-group-label"))) (if (string? v) v "")))
;; The label(s) to try for a node's pool — the configured one, else the known
;; cloud node-pool labels in priority order.
(define (k8s--node-group-candidates)
  (let ((lbl (k8s--node-group-label)))
    (if (equal? lbl "")
        (list "eks.amazonaws.com/nodegroup"
              "cloud.google.com/gke-nodepool"
              "karpenter.sh/nodepool"
              "kubernetes.azure.com/agentpool"
              "agentpool")
        (list lbl))))
;; node-name -> pool group. `-L a,b,c` appends those label columns (value or
;; "<none>") LAST to the table, so the pool is the first present of the trailing
;; N fields — no JSON, no jsonpath escaping of dotted label keys.
(define (k8s--node-group-map cands)
  (let ((n (length cands)))
    (map (lambda (ln)
           (let* ((f (k8s--fields ln))
                  (name (if (null? f) "" (car f))))
             (cons name (k8s--first-present (k8s--last-n f n)))))
         (k8s--lines (k8s--run (list "get" "nodes" "--no-headers"
                                     "-L" (string-join cands ",")))))))

;; ── rendering ─────────────────────────────────────────────────────────────────
;; Record which resource sits on a rendered line (with its namespace), so
;; d/l/y/s/x can resolve it and act in the right namespace.
(define (k8s--record line kind name ns)
  (k8s--st! 'linemap (cons (list line kind name ns) (k8s--st 'linemap))))

;; A foldable section for one `kubectl get`: header row dim, one colored row per
;; resource. `namespaced?` decides `-n`/`-A`; in all-namespaces mode kubectl
;; prepends a NAMESPACE column, so name/status shift right by one (`off`).
;; `status-idx` is the status column's index in single-namespace output.
(define (k8s--emit-table id label kind namespaced? get-args status-idx)
  (let* ((off (if (and namespaced? (k8s--st 'all-ns)) 1 0))
         (out (k8s--run (append get-args (k8s--get-ns-args namespaced?))))
         (all (k8s--lines out)))
    (section-open id
                  (string-append label " (" (number->string (max 0 (- (length all) 1))) ")")
                  "k8s-section")
    (if (or (null? all) (null? (cdr all)))
        (section-line "    (none)" "k8s-dim")
        (begin
          (section-line (string-append "  " (car all)) "k8s-dim")  ; column header
          (for-each
           (lambda (row)
             (let* ((fields (k8s--fields row))
                    (name (k8s--nth-or fields off ""))
                    (ns   (if (= off 1) (k8s--nth-or fields 0 "") (k8s--st 'namespace)))
                    (face (k8s--status-face kind (k8s--nth-or fields (+ status-idx off) ""))))
               (k8s--record (section-point-line) kind name ns)
               (section-line (string-append "  " row) face)))
           (cdr all))))
    (section-close id)
    (section-line "" #f)))

;; Render `records` grouped under one outer foldable section `id`/`label`, a
;; nested foldable subsection per group. A record is (group display-row name ns
;; face kind); each group heading takes its worst member's face, so a collapsed
;; group still flags trouble. Shared by pods (by workload) and nodes (by pool).
(define (k8s--emit-groups id label header records)
  (let ((groups (k8s--uniq (map car records)))
        (idstr  (symbol->string id)))
    (section-open id
                  (string-append label " (" (number->string (length records)) ")") "k8s-section")
    (if (null? records)
        (section-line "    (none)" "k8s-dim")
        (begin
          (when (not (equal? header "")) (section-line (string-append "    " header) "k8s-dim"))
          (for-each
           (lambda (g)
             (let* ((members (filter (lambda (x) (equal? (car x) g)) records))
                    (gface (k8s--worst-face (map (lambda (m) (nth m 4)) members))))
               (section-open (string-append idstr "/" g)
                             (string-append "  " g " (" (number->string (length members)) ")")
                             gface)
               (for-each
                (lambda (m)
                  (k8s--record (section-point-line) (nth m 5) (nth m 2) (nth m 3))
                  (section-line (string-append "    " (nth m 1)) (nth m 4)))
                members)
               (section-close (string-append idstr "/" g))))
           groups)))
    (section-close id)
    (section-line "" #f)))

;; Pods, grouped by owning workload. The `-o wide` rows give the display columns
;; (rich STATUS, restarts, node); a second custom-columns query resolves each
;; pod's group. Fold a group to hide its pods, fold "Pods" to hide everything.
(define (k8s--emit-pods)
  (let* ((off  (if (k8s--st 'all-ns) 1 0))
         (all  (k8s--lines (k8s--run (append (list "get" "pods" "-o" "wide")
                                             (k8s--get-ns-args #t)))))
         (header (if (null? all) "" (car all)))
         (body   (if (null? all) '() (cdr all)))
         (gmap (k8s--pod-group-map))
         (recs (map (lambda (row)
                      (let* ((f (k8s--fields row))
                             (name (k8s--nth-or f off ""))
                             (ns   (if (= off 1) (k8s--nth-or f 0 "") (k8s--st 'namespace)))
                             (key  (string-append ns "/" name))
                             (grp  (let ((g (alist-ref gmap key))) (if g g "(no controller)")))
                             (face (k8s--phase-face (k8s--nth-or f (+ 2 off) ""))))
                        (list grp row name ns face "pod")))
                    body)))
    (k8s--emit-groups 'k8s-pods "Pods" header recs)))

;; Nodes. Adaptive: group by node pool when it yields 2+ groups, else stay flat
;; (single-pool / kind / minikube clusters just show a plain Nodes section).
(define (k8s--emit-nodes)
  (let* ((all    (k8s--lines (k8s--run (list "get" "nodes" "-o" "wide"))))
         (header (if (null? all) "" (car all)))
         (body   (if (null? all) '() (cdr all)))
         (gmap   (k8s--node-group-map (k8s--node-group-candidates)))
         (recs   (map (lambda (row)
                        (let* ((f (k8s--fields row))
                               (name (if (null? f) "" (car f)))
                               (grp  (let ((g (alist-ref gmap name))) (if g g "(no pool)")))
                               (face (k8s--node-face (k8s--nth-or f 1 ""))))
                          (list grp row name "" face "node")))
                      body))
         (groups (k8s--uniq (map car recs))))
    (if (< (length groups) 2)
        (k8s--emit-flat-nodes header body)
        (k8s--emit-groups 'k8s-nodes "Nodes" header recs))))
(define (k8s--emit-flat-nodes header body)
  (section-open 'k8s-nodes
                (string-append "Nodes (" (number->string (length body)) ")") "k8s-section")
  (if (null? body)
      (section-line "    (none)" "k8s-dim")
      (begin
        (section-line (string-append "  " header) "k8s-dim")
        (for-each (lambda (row)
                    (let ((f (k8s--fields row)))
                      (k8s--record (section-point-line) "node" (if (null? f) "" (car f)) "")
                      (section-line (string-append "  " row)
                                    (k8s--node-face (k8s--nth-or f 1 "")))))
                  body)))
  (section-close 'k8s-nodes)
  (section-line "" #f))

;; Recent Warning events (their own coloring, not a resource — no line record).
(define (k8s--emit-events)
  (let* ((out (k8s--run (append (list "get" "events" "--field-selector" "type=Warning")
                                (k8s--get-ns-args #t))))
         (all (k8s--lines out)))
    (section-open 'k8s-events
                  (string-append "Warnings (" (number->string (max 0 (- (length all) 1))) ")")
                  "k8s-section")
    (if (or (null? all) (null? (cdr all)))
        (section-line "    (no warnings)" "k8s-dim")
        (begin
          (section-line (string-append "  " (car all)) "k8s-dim")
          (for-each (lambda (row) (section-line (string-append "  " row) "k8s-warn"))
                    (cdr all))))
    (section-close 'k8s-events)
    (section-line "" #f)))

(define (k8s--emit-header)
  (let ((ctx (k8s--st 'context)))
    (section-line
     (string-append "Context: " (if (equal? ctx "") "(none)" ctx)
                    "    Namespace: " (if (k8s--st 'all-ns) "<all>" (k8s--st 'namespace))
                    (if (k8s--st 'auto) "    [auto-refresh]" ""))
     "k8s-header")
    (section-line
     (string-append "  r refresh · TAB fold · d describe · l logs · s shell/scale · "
                    "y yaml · x delete · N ns · A all-ns · C ctx · a auto · ? more · q quit")
     "k8s-dim")
    (section-line "" #f)))

;; Rebuild the dashboard from live kubectl queries. `quiet` updates the buffer
;; IN PLACE without stealing focus (background auto-refresh while the user is in
;; another buffer) — like magit's quiet refresh, it skips fold/accent overlays,
;; which re-apply on the next in-front render. The interactive path preserves
;; point and re-applies folds.
(define (k8s--render quiet)
  (let ((line (if (equal? (current-buffer) "*k8s-dashboard*") (buffer-line) 0)))
    (k8s--resolve-context!)
    (k8s--st! 'linemap '())
    (section-begin)
    (k8s--emit-header)
    (k8s--emit-nodes)
    (k8s--emit-table 'k8s-deploys "Deployments" "deployment" #t (list "get" "deployments")       1)
    (k8s--emit-table 'k8s-hpa     "Autoscalers" "hpa"        #t (list "get" "hpa")                2)
    (k8s--emit-pods)
    (k8s--emit-table 'k8s-svcs    "Services"    "service"    #t (list "get" "services")          0)
    (k8s--emit-events)
    (if quiet
        (render-buffer-quiet "*k8s-dashboard*" "k8s-mode" (section-text) (section-line-faces))
        (begin
          (section-render "*k8s-dashboard*" "k8s-mode")
          (goto-line line)))))

(define-command (k8s-refresh) (k8s--render #f))
;; In-place refresh that never steals focus — for the background auto-refresh.
(define (k8s--refresh-quiet)
  (when (member "*k8s-dashboard*" (buffer-names)) (k8s--render #t)))

;; ── the entry command ─────────────────────────────────────────────────────────
(define-command (k8s-dashboard)
  (k8s--resolve-context!)
  (when (not (k8s--st 'ns-resolved))
    (k8s--resolve-namespace!)
    (k8s--st! 'ns-resolved #t))
  (k8s-refresh))

;; ── navigation / fold ─────────────────────────────────────────────────────────
(define-command (k8s-toggle-fold) (section-toggle-at-point))

;; The resource on the current line, as (line kind name ns), or #f.
(define (k8s--resource-at)
  (let ((ln (buffer-line)))
    (let loop ((m (k8s--st 'linemap)))
      (cond ((null? m) #f)
            ((= (car (car m)) ln) (car m))
            (else (loop (cdr m)))))))
(define (k8s--require-kind r kind what)
  (if (and r (equal? (nth r 1) kind)) #t
      (begin (message (string-append "k8s: move point to a " what)) #f)))

;; ── copy to clipboard ─────────────────────────────────────────────────────────
;; vim/helix yank does NOT work in these special read-only buffers: the editor's
;; modal layer overlays only MOTION on magit-style buffers (via `evil-normal:<mode>`),
;; never the global evil-visual keymap, so the `y` operator / visual-yank never
;; run and nothing reaches the clipboard. So we bind explicit copy commands that
;; call `clipboard-set` directly — exactly how magit/dired expose `y`.
(define (k8s--current-line-text)
  (k8s--nth-or (split-many (buffer-string) "\n") (buffer-line) ""))
(define-command (k8s-copy-line)
  (let ((s (k8s--current-line-text)))
    (clipboard-set s)
    (message (string-append "Copied line: " (trim-start s)))))
(define-command (k8s-copy-buffer)
  (clipboard-set (buffer-string))
  (message "k8s: copied whole buffer to clipboard"))
;; Status buffer: copy the resource name at point (fallback: the whole line).
(define-command (k8s-copy)
  (let ((r (k8s--resource-at)))
    (if r
        (begin (clipboard-set (nth r 2)) (message (string-append "Copied " (nth r 2))))
        (k8s-copy-line))))

;; ── describe / yaml ───────────────────────────────────────────────────────────
(define-command (k8s-describe)
  (let ((r (k8s--resource-at)))
    (if r
        (let ((out (k8s--run (append (list "describe" (nth r 1) (nth r 2))
                                     (k8s--ns-args-for r)))))
          (render-buffer "*k8s-describe*" "k8s-detail-mode"
                         (if (k8s--blank? out) "(no output)" (trim-end out)) '()))
        (message "k8s: point is not on a resource"))))

;; YAML opens in a REAL file buffer (a temp `.yaml`), not a special render-buffer,
;; so it auto-detects into yaml highlighting AND every keymap works normally —
;; evil/helix/emacs motion, `/` search, native `yy` yank, the lot. A render-buffer
;; is "special" and only gets the motion overlay, so search etc. wouldn't work.
(define (k8s--tmpdir)
  (let ((t (getenv "TMPDIR")))
    (cond ((equal? t "") "/tmp")
          ((ends-with? t "/") (substring t 0 (- (string-length t) 1)))
          (else t))))
(define (k8s--yaml-slug ns kind name)
  (string-append (if (equal? ns "") "cluster" ns) "-" kind "-" name ".yaml"))
(define-command (k8s-yaml)
  (let ((r (k8s--resource-at)))
    (if r
        (let* ((kind (nth r 1)) (name (nth r 2)) (ns (nth r 3))
               (out  (k8s--run (append (list "get" kind name "-o" "yaml")
                                       (k8s--ns-args-for r))))
               (slug (k8s--yaml-slug ns kind name))
               (path (string-append (k8s--tmpdir) "/macros-k8s/" slug)))
          (write-file path (if (k8s--blank? out) "# (no output)\n" (trim-end out)))
          (kill-buffer-named slug)   ; drop a stale view so find-file re-reads
          (open-file path))
        (message "k8s: point is not on a resource"))))

;; ── logs (last *k8s-log-tail* lines) ──────────────────────────────────────────
(define-command (k8s-logs)
  (let ((r (k8s--resource-at)))
    (when (k8s--require-kind r "pod" "pod for logs")
      (let* ((name (nth r 2))
             (out (k8s--run (list "logs" (string-append "--tail=" (number->string *k8s-log-tail*))
                                  "-n" (nth r 3) name))))
        (render-buffer (string-append "*k8s-logs:" name "*") "k8s-detail-mode"
                       (if (k8s--blank? out) "(no logs)" (trim-end out)) '())))))

;; ── shell (kubectl exec -it, in a half-screen terminal) ───────────────────────
;; Split the dashboard window in half, drop into the new pane, and run an
;; interactive shell inside the pod. Focus lands in the terminal so you can type;
;; `C-x o` returns to the dashboard, `C-x k` kills the shell.
(define (k8s--open-shell pod ns)
  (let ((sh (k8s--shell)))
    (split-window-below)                     ; half-height pane across the bottom
    (other-window)                           ; move focus into it
    (make-terminal (string-append "*k8s-shell:" pod "*") *k8s-command*
                   (list "exec" "-it" pod "-n" ns "--" sh))
    (message (string-append "shell → " pod " (" ns ") : " sh))))
(define-command (k8s-shell)
  (let ((r (k8s--resource-at)))
    (when (k8s--require-kind r "pod" "pod to open a shell")
      (k8s--open-shell (nth r 2) (nth r 3)))))

;; ── scale (deployments) ───────────────────────────────────────────────────────
(define-command (k8s-scale)
  (let ((r (k8s--resource-at)))
    (when (k8s--require-kind r "deployment" "deployment to scale")
      (let ((name (nth r 2)) (ns (nth r 3)))
        (read-string (string-append "Scale " name " to replicas: ")
                     (lambda (input) (k8s--scale-to name ns input)))))))
;; `s` is context-sensitive: a shell on a pod, scale on a deployment.
(define-command (k8s-shell-or-scale)
  (let ((r (k8s--resource-at)))
    (cond ((and r (equal? (nth r 1) "pod"))        (k8s--open-shell (nth r 2) (nth r 3)))
          ((and r (equal? (nth r 1) "deployment")) (k8s-scale))
          (else (message "k8s: 's' opens a shell on a pod or scales a deployment")))))
(define (k8s--scale-to name ns input)
  (let ((n (trim-end (trim-start input))))
    (when (not (equal? n ""))
      (let ((res (k8s--run-full (list "scale" (string-append "deployment/" name)
                                      (string-append "--replicas=" n) "-n" ns))))
        (if (equal? (car res) "0")
            (begin (message (string-append "scaled " name " → " n)) (k8s-refresh))
            (message (string-append "scale failed: " (trim-end (nth res 2)))))))))

;; ── delete (pods, confirmed) ──────────────────────────────────────────────────
(define-command (k8s-delete)
  (let ((r (k8s--resource-at)))
    (when (k8s--require-kind r "pod" "pod to delete")
      (let ((name (nth r 2)) (ns (nth r 3)))
        (k8s--st! 'confirm (lambda () (k8s--delete-pod name ns)))
        (y-or-n-p (string-append "Delete pod " name " (" ns ")? ") 'k8s--confirm-yes)))))
(define (k8s--confirm-yes ans)
  (let ((t (k8s--st 'confirm)))
    (k8s--st! 'confirm #f)
    (when (and t (equal? ans "yes")) (t))))
(define (k8s--delete-pod name ns)
  (let ((res (k8s--run-full (list "delete" "pod" name "-n" ns))))
    (if (equal? (car res) "0")
        (begin (message (string-append "deleting " name)) (k8s-refresh))
        (message (string-append "delete failed: " (trim-end (nth res 2)))))))

;; ── namespace / context switch ────────────────────────────────────────────────
(define (k8s--namespaces)
  (k8s--lines (k8s--run (list "get" "namespaces" "-o" "custom-columns=:.metadata.name"
                              "--no-headers"))))
(define (k8s--contexts)
  (k8s--lines (k8s--run (list "config" "get-contexts" "-o" "name"))))
(define-command (k8s-set-namespace)
  (completing-read "Namespace: " (k8s--namespaces)
    (lambda (ns) (when (not (k8s--blank? ns))
                   (k8s--st! 'all-ns #f)            ; picking one exits all-ns view
                   (k8s--st! 'namespace (trim-end ns)) (k8s-refresh)))))
;; Toggle between the single-namespace view and all namespaces (kubectl -A).
(define-command (k8s-toggle-all-namespaces)
  (k8s--st! 'all-ns (not (k8s--st 'all-ns)))
  (message (if (k8s--st 'all-ns) "k8s: showing all namespaces"
               (string-append "k8s: namespace " (k8s--st 'namespace))))
  (k8s-refresh))
;; Set the node-grouping label at runtime (empty = auto-detect). Writes the
;; option store, so `k8s--node-group-label` reads it back. Configure statically
;; with `(set-option "k8s-node-group-label" …)`; this command adds M-x + refresh.
(define (k8s--apply-node-group-label label)
  (let ((lbl (trim-end (trim-start label))))
    (set-option "k8s-node-group-label" lbl)
    (message (string-append "k8s: node grouping by " (if (equal? lbl "") "(auto)" lbl)))
    (when (equal? (current-buffer) "*k8s-dashboard*") (k8s-refresh))))
(define-command (k8s-set-node-group-label . rest)
  (if (null? rest)
      (read-string "Node group label (empty = auto): " k8s--apply-node-group-label)
      (k8s--apply-node-group-label (car rest))))
(define-command (k8s-set-context)
  (completing-read "Context: " (k8s--contexts)
    (lambda (ctx) (when (not (k8s--blank? ctx))
                    (k8s--run (list "config" "use-context" (trim-end ctx)))
                    (k8s--resolve-namespace!) (k8s-refresh)))))

;; ── dispatch popup (?) ────────────────────────────────────────────────────────
;; `?` opens a transient of the actions available on the resource under point —
;; pod / deployment / node get their own menus; anywhere else, a view menu. The
;; popup closes on a key and runs its command, which re-reads point (still on the
;; same row), so the existing action commands work unchanged.
(define-command (k8s-dispatch)
  (let ((r (k8s--resource-at)))
    (cond
     ((and r (equal? (nth r 1) "pod"))
      (transient (string-append "Pod: " (nth r 2) "  (" (nth r 3) ")")
        (list (list "Inspect"
                    (list "d" "Describe"       'k8s-describe)
                    (list "y" "YAML"           'k8s-yaml)
                    (list "l" "Logs"           'k8s-logs))
              (list "Act"
                    (list "s" "Shell"          'k8s-shell)
                    (list "x" "Delete"         'k8s-delete)
                    (list "q" "Close"          'transient-quit)))))
     ((and r (equal? (nth r 1) "deployment"))
      (transient (string-append "Deployment: " (nth r 2) "  (" (nth r 3) ")")
        (list (list "Inspect"
                    (list "d" "Describe"       'k8s-describe)
                    (list "y" "YAML"           'k8s-yaml))
              (list "Act"
                    (list "s" "Scale"          'k8s-scale)
                    (list "q" "Close"          'transient-quit)))))
     ((and r (equal? (nth r 1) "node"))
      (transient (string-append "Node: " (nth r 2))
        (list (list "Inspect"
                    (list "d" "Describe"       'k8s-describe)
                    (list "y" "YAML"           'k8s-yaml)
                    (list "q" "Close"          'transient-quit)))))
     ((and r (equal? (nth r 1) "hpa"))
      (transient (string-append "HPA: " (nth r 2) "  (" (nth r 3) ")")
        (list (list "Inspect"
                    (list "d" "Describe"       'k8s-describe)
                    (list "y" "YAML"           'k8s-yaml)
                    (list "q" "Close"          'transient-quit)))))
     (else
      (transient "Kubernetes"
        (list (list "View"
                    (list "r" "Refresh"          'k8s-refresh)
                    (list "shift-n" "Namespace"  'k8s-set-namespace)
                    (list "shift-a" "All namespaces" 'k8s-toggle-all-namespaces)
                    (list "shift-c" "Context"    'k8s-set-context)
                    (list "a" "Auto-refresh"     'k8s-toggle-auto)
                    (list "q" "Close"            'transient-quit))))))))

;; ── auto-refresh polling ──────────────────────────────────────────────────────
;; A single self-rearming timer. When the dashboard is in front, `k8s--tick`
;; refreshes it normally (preserving point); when the user is in another buffer
;; (reading logs, describe, …) it refreshes the dashboard SILENTLY in place —
;; never swapping focus back to it. The chain stops once the dashboard buffer is
;; gone or auto-refresh is toggled off.
(define (k8s--arm-timer)
  (when (not (k8s--st 'timer-armed))
    (k8s--st! 'timer-armed #t)
    (run-with-timer *k8s-auto-refresh-ms* "k8s--tick")))
(define-command (k8s--tick)
  (k8s--st! 'timer-armed #f)
  (when (and (k8s--st 'auto) (member "*k8s-dashboard*" (buffer-names)))
    (if (equal? (current-buffer) "*k8s-dashboard*")
        (k8s-refresh)          ; in front → normal refresh, point preserved
        (k8s--refresh-quiet))  ; elsewhere → silent in-place update, no focus swap
    (k8s--arm-timer)))
(define-command (k8s-toggle-auto)
  (k8s--st! 'auto (not (k8s--st 'auto)))
  (if (k8s--st 'auto)
      (begin (message (string-append "k8s: auto-refresh on ("
                                     (number->string (quotient *k8s-auto-refresh-ms* 1000)) "s)"))
             (k8s--arm-timer))
      (message "k8s: auto-refresh off"))
  (when (equal? (current-buffer) "*k8s-dashboard*") (k8s-refresh)))

;; ── keymaps ───────────────────────────────────────────────────────────────────
;; Status buffer (no line-number gutter — it's a list view, not code).
(set-option "line-numbers:k8s-mode" "false")
(define-key "k8s-mode" "r" 'k8s-refresh)
(define-key "k8s-mode" "g" 'k8s-refresh)
(define-key "k8s-mode" "tab" 'k8s-toggle-fold)
(define-key "k8s-mode" "enter" 'k8s-toggle-fold)
(define-key "k8s-mode" "d" 'k8s-describe)
(define-key "k8s-mode" "l" 'k8s-logs)
(define-key "k8s-mode" "y" 'k8s-yaml)
(define-key "k8s-mode" "s" 'k8s-shell-or-scale)   ; pod → shell, deployment → scale
(define-key "k8s-mode" "x" 'k8s-delete)
(define-key "k8s-mode" "shift-n" 'k8s-set-namespace)
(define-key "k8s-mode" "shift-a" 'k8s-toggle-all-namespaces)
(define-key "k8s-mode" "shift-c" 'k8s-set-context)
(define-key "k8s-mode" "a" 'k8s-toggle-auto)
(define-key "k8s-mode" "?" 'k8s-dispatch)
(define-key "k8s-mode" "shift-y" 'k8s-copy)        ; Y — copy resource name at point
(define-key "k8s-mode" "n" 'next-line)
(define-key "k8s-mode" "p" 'previous-line)
(define-key "k8s-mode" "q" 'kill-buffer)

;; Detail buffers: describe / yaml / logs. `y y` copies the current line, `Y` the
;; whole buffer (real vim yank can't reach these read-only buffers — see
;; k8s-copy-line). Bound in the base keymap so they work with or without evil.
(set-option "line-numbers:k8s-detail-mode" "false")
(define-key "k8s-detail-mode" "y y" 'k8s-copy-line)
(define-key "k8s-detail-mode" "shift-y" 'k8s-copy-buffer)
(define-key "k8s-detail-mode" "n" 'next-line)
(define-key "k8s-detail-mode" "p" 'previous-line)
(define-key "k8s-detail-mode" "q" 'kill-buffer)

;; ── evil / helix motion overlays ──────────────────────────────────────────────
;; Special (render-buffer) buffers drive their own keymaps, so the GLOBAL evil /
;; helix motion never reaches them — the editor consults an `evil-normal:<mode>` /
;; `helix-normal:<mode>` overlay BEFORE the buffer's own keymap. We register our
;; own so j/k (and friends) traverse the dashboard and scroll the detail/log
;; buffers, without depending on or mutating any core mode list. Inert under plain
;; Emacs, where the overlays aren't consulted. (Arrow keys and n/p work anyway.)

;; Status buffer: overlay only j/k (+ G / C-d / C-u) so the letter action keys
;; (d/l/y/s/x/a/r/g) stay free — matching magit. No `g g` overlay: single `g`
;; must remain refresh.
(define (k8s--bind-status-motion km)
  (define-key km "j" 'next-line)
  (define-key km "k" 'previous-line)
  (define-key km "shift-g" 'evil-goto-last-line)
  (define-key km "ctrl-d" 'evil-scroll-down)
  (define-key km "ctrl-u" 'evil-scroll-up))
(k8s--bind-status-motion "evil-normal:k8s-mode")
(k8s--bind-status-motion "helix-normal:k8s-mode")

;; Detail / log buffers are read-only text you scroll like a file, so they earn
;; the full read-only motion set (matching evil-collection's read-only modes).
(define (k8s--bind-readonly-motion km)
  (define-key km "j" 'next-line)
  (define-key km "k" 'previous-line)
  (define-key km "h" 'backward-char)
  (define-key km "l" 'forward-char)
  (define-key km "w" 'forward-word-start)
  (define-key km "b" 'backward-word)
  (define-key km "e" 'evil-forward-word-end)
  (define-key km "0" 'move-beginning-of-line)
  (define-key km "$" 'move-end-of-line)
  (define-key km "^" 'evil-first-non-blank)
  (define-key km "g g" 'evil-goto-first-line)
  (define-key km "shift-g" 'evil-goto-last-line)
  (define-key km "ctrl-d" 'evil-scroll-down)
  (define-key km "ctrl-u" 'evil-scroll-up))
(k8s--bind-readonly-motion "evil-normal:k8s-detail-mode")
(k8s--bind-readonly-motion "helix-normal:k8s-detail-mode")
