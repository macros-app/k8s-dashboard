;;; macros-k8s — a Kubernetes dashboard for the macros editor, in Steel.
;;;
;;; A magit-style porcelain for `kubectl`. It sits on the same editor primitives
;;; magit.scm / macros-jj use — the Rust core knows nothing about k8s:
;;;   * `call-process` / `call-process-full` — run kubectl, capture stdout/stderr
;;;   * lib-section (`section-open`/`section-line`/`section-render`) — foldable,
;;;     navigable read-only status buffer with persistent fold state
;;;   * `render-buffer` / `render-buffer-quiet` — draw detail buffers
;;;   * `make-terminal` + `split-window-below` — `s` opens a pod shell in a pane;
;;;     `terminal-exit-hook` closes that pane when the shell exits
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
(define *k8s-spark-samples* 16)      ; CPU/memory readings kept per pod (sparkline width)
(define *k8s-chart-columns* 60)      ; time buckets across the metrics heatmap

;; The shell `s` runs inside a pod (via `kubectl exec -it`). Configured through
;; the editor's OPTION store, not a Scheme var — a plain `(define *k8s-shell* …)`
;; before load is clobbered by the package's own define, and a loaded file's own
;; vars can't be set! from init.scm (each file is its own Steel unit). `set-option`
;; writes to the Rust-side option map, so this reads cleanly regardless of load
;; order:  (set-option "k8s-shell" "/bin/sh")  in init.scm.
(define (k8s--shell)
  (let ((v (get-option "k8s-shell")))
    (if (and (string? v) (not (equal? v ""))) v "/bin/bash")))
;; Where focus lands after `s` opens a pod shell: "terminal" (default — type
;; straight away) or "dashboard" (keep browsing; `C-x o` jumps into the shell):
;;   (set-option "k8s-shell-focus" "dashboard")
(define (k8s--shell-focus-dashboard?)
  (equal? (get-option "k8s-shell-focus") "dashboard"))
;; When a pod shell exits (`exit`, pod deleted, connection dropped) its pane and
;; buffer close automatically. Keep the dead buffer around instead with:
;;   (set-option "k8s-shell-keep-on-exit" "true")
;; (Opt-OUT via a truthy value: an unset option and `#f` both read back as #f.)
(define (k8s--shell-keep-on-exit?)
  (let ((v (get-option "k8s-shell-keep-on-exit")))
    (or (eq? v #t) (equal? v "true"))))
;; Metrics history (the `M` charts). A background sampler takes a `kubectl top
;; nodes` reading every k8s-metrics-interval seconds while the dashboard or the
;; metrics buffer is open, stores it per context on disk, and drops readings
;; older than k8s-metrics-retention-hours, so the charts fill in over a day and
;; stay bounded:
;;   (set-option "k8s-metrics-interval" 30)          ; default 60
;;   (set-option "k8s-metrics-retention-hours" 72)   ; default 24
(define (k8s--opt-number key default)
  (let ((v (get-option key)))
    (cond ((and (number? v) (> v 0)) v)
          ((and (string? v) (string->number v) (> (string->number v) 0)) (string->number v))
          (else default))))
(define (k8s--metrics-interval) (k8s--opt-number "k8s-metrics-interval" 60))
(define (k8s--retention-secs) (* 3600 (k8s--opt-number "k8s-metrics-retention-hours" 24)))
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
   'metrics     (hash) ; "ns/pod" -> recent (cpu-millicores mem-MiB) readings
   'metrics-ok  #f    ; did the last `kubectl top pods` succeed?
   'metrics-wait 0    ; renders to skip before retrying a failed `kubectl top`
   'store       '()   ; node readings, oldest first: (epoch node cpu-m cpu% mem-MiB mem%)
   'store-ctx   #f    ; the context `store` belongs to (loaded from its file)
   'sampler-armed #f  ; is the background metrics sampler scheduled?
   'metrics-at  #f    ; when the last successful `kubectl top pods` reading was taken
   'wl-store    '()   ; workload readings, oldest first: (epoch ns group cpu-sum mem-sum pods)
   'wl-store-ctx #f   ; the context `wl-store` belongs to
   'wl-recorded-at #f ; the pod reading last folded into `wl-store`
   'built       #f    ; buffer whose sections lib-section holds (it keeps one set)
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
;; face kind [segs]) — `segs`, optional, are (text face) pieces appended to the
;; row (pod sparklines); each group heading takes its worst member's face, so a collapsed
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
                  (k8s--line-with-segs (string-append "    " (nth m 1))
                                       (if (> (length m) 6) (nth m 6) '())
                                       (nth m 4)))
                members)
               (section-close (string-append idstr "/" g))))
           groups)))
    (section-close id)
    (section-line "" #f)))

;; ── pod metrics sparklines ──────────────────────────────────────────────────
;; Each render samples `kubectl top pods` (needs metrics-server) and keeps the
;; last *k8s-spark-samples* readings per pod; pod rows then end with CPU and
;; memory sparklines drawn by the editor's plot.scm. Both are optional: with no
;; metrics-server, or on an editor build without plot.scm, rows render as before.

;; plot.scm's sparkline function, or #f on editors without it. Looked up through
;; eval-string: naming it directly would make this whole file fail to load on
;; older builds (Steel rejects a unit over one unknown identifier).
(define k8s--sparkline
  (if (member "plot-sparkline-string" (function-list))
      (eval-string "plot-sparkline-string")
      #f))

;; A failed `kubectl top` (no metrics-server) is retried only every this many
;; renders, so clusters without metrics don't pay for it on every refresh.
(define k8s--metrics-retry 12)

(define (k8s--strip-suffix s suf) (substring s 0 (- (string-length s) (string-length suf))))
(define (k8s--num s) (let ((n (string->number s))) (if n (exact->inexact n) #f)))

;; kubectl CPU quantity → millicores: "250m" → 250, "2" → 2000.
(define (k8s--parse-cpu s)
  (if (ends-with? s "m")
      (k8s--num (k8s--strip-suffix s "m"))
      (let ((n (k8s--num s))) (if n (* n 1000.0) #f))))

;; kubectl memory quantity → MiB: "128Mi" → 128, "2Gi" → 2048, bare bytes too.
(define (k8s--parse-mem s)
  (let ((scaled (lambda (suf factor)
                  (let ((n (k8s--num (k8s--strip-suffix s suf)))) (if n (* n factor) #f)))))
    (cond ((ends-with? s "Ki") (scaled "Ki" (/ 1.0 1024)))
          ((ends-with? s "Mi") (scaled "Mi" 1.0))
          ((ends-with? s "Gi") (scaled "Gi" 1024.0))
          ((ends-with? s "Ti") (scaled "Ti" 1048576.0))
          (else (let ((n (k8s--num s))) (if n (/ n 1048576.0) #f))))))

;; Take one `kubectl top pods` reading. History is rebuilt from the pods in this
;; reading, so deleted pods drop out instead of accumulating.
(define (k8s--sample-pod-metrics!)
  (cond
    ((not k8s--sparkline) #f)
    ((> (k8s--st 'metrics-wait) 0)
     (k8s--st! 'metrics-wait (- (k8s--st 'metrics-wait) 1)))
    (else
     (let ((res (k8s--run-full (append (list "top" "pods" "--no-headers")
                                       (k8s--get-ns-args #t)))))
       (if (not (equal? (car res) "0"))
           (begin (k8s--st! 'metrics-ok #f)
                  (k8s--st! 'metrics-wait k8s--metrics-retry))
           (let ((off  (if (k8s--st 'all-ns) 1 0))
                 (old  (k8s--st 'metrics))
                 (hist (hash)))
             (for-each
              (lambda (row)
                (let* ((f    (k8s--fields row))
                       (name (k8s--nth-or f off ""))
                       (ns   (if (= off 1) (k8s--nth-or f 0 "") (k8s--st 'namespace)))
                       (key  (string-append ns "/" name))
                       (cpu  (k8s--parse-cpu (k8s--nth-or f (+ off 1) "")))
                       (mem  (k8s--parse-mem (k8s--nth-or f (+ off 2) "")))
                       (prev (let ((h (hash-try-get old key))) (if h h '()))))
                  (when (and cpu mem)
                    (set! hist (hash-insert hist key
                                            (k8s--last-n (append prev (list (list cpu mem)))
                                                         *k8s-spark-samples*))))))
              (k8s--lines (cadr res)))
             (k8s--st! 'metrics hist)
             (k8s--st! 'metrics-ok #t)
             (k8s--st! 'metrics-at (string->number (current-time "%s")))))))))

;; `x` to one decimal place via integer arithmetic ("1.2", never "1.2000000000000002").
(define (k8s--one-decimal x)
  (let ((n (inexact->exact (round (* x 10)))))
    (string-append (number->string (quotient n 10)) "." (number->string (abs (remainder n 10))))))
(define (k8s--fmt-cpu m)
  (if (>= m 1000)
      (k8s--one-decimal (/ m 1000))               ; cores, one decimal
      (string-append (number->string (inexact->exact (round m))) "m")))
(define (k8s--fmt-mem mib)
  (if (>= mib 1024)
      (string-append (k8s--one-decimal (/ mib 1024)) "Gi")
      (string-append (number->string (inexact->exact (round mib))) "Mi")))

;; A sparkline in a fixed width, starting under its column heading and growing
;; rightward as readings arrive (newest reading last). Scaled from 0, so a pod's
;; bars compare against its own recent peak.
(define (k8s--spark values)
  (pad-right (k8s--sparkline values 'min 0) *k8s-spark-samples*))

;; The CPU/memory columns appended to a pod row, as (text face) segments; '()
;; when there is nothing to draw.
(define (k8s--pod-metric-segs key)
  (let ((samples (hash-try-get (k8s--st 'metrics) key)))
    (if (or (not (k8s--st 'metrics-ok)) (not samples) (null? samples))
        '()
        (let ((cpus (map car samples)) (mems (map cadr samples)))
          (list (list "  " #f)
                (list (k8s--spark cpus) "plot-series-0")
                (list (string-append " " (pad-right (k8s--fmt-cpu (last cpus)) 6) " ") "k8s-dim")
                (list (k8s--spark mems) "plot-series-1")
                (list (string-append " " (k8s--fmt-mem (last mems))) "k8s-dim"))))))

;; Header text matching k8s--pod-metric-segs' columns.
(define (k8s--pod-metric-header)
  (string-append "  " (pad-right "CPU" (+ *k8s-spark-samples* 8)) "MEMORY"))

;; Emit `text` plus (text face) `segs` as one section line with whole-line face
;; `face`; each segment that has a face becomes a byte-range accent over it.
(define (k8s--line-with-segs text segs face)
  (let ((b (section-point-byte)))
    (let loop ((segs segs) (at (utf8-length text)) (acc text) (accents '()))
      (if (null? segs)
          (begin
            (section-line acc face)
            (for-each (lambda (a) (section-accent (+ b (car a)) (+ b (cadr a)) (nth a 2)))
                      accents))
          (let* ((seg (car segs)) (n (utf8-length (car seg))))
            (loop (cdr segs) (+ at n) (string-append acc (car seg))
                  (if (cadr seg) (cons (list at (+ at n) (cadr seg)) accents) accents)))))))

;; ── metrics dashboard (M / M-x k8s-metrics) ─────────────────────────────────
;; A second buffer of charts: cluster CPU and memory over time, node utilization
;; (now, and as a heatmap over time), the heaviest pods, the pod memory
;; distribution, and pod health. The charts over time read a stored history of
;; `kubectl top nodes` readings (see k8s--sample-tick), kept per context on disk
;; for k8s-metrics-retention-hours. Needs the editor's plot.scm (looked up by
;; name, like k8s--sparkline) and metrics-server for the usage charts; pod health
;; works without either.

;; One of plot.scm's functions by name, or #f on editors without it.
(define (k8s--plot-fn name)
  (if (member name (function-list)) (eval-string name) #f))

(define (k8s--now) (string->number (current-time "%s")))

;; ── stored node history ──
;; Records are (epoch node cpu-millicores cpu% mem-MiB mem%). One file per
;; context under the editor's persistence directory (~/.config/macros on builds
;; without it), one tab-separated record per line.
(define (k8s--store-dir)
  (string-append (if (member "persistence-directory" (function-list))
                     (eval-string "(persistence-directory)")
                     (string-append (getenv "HOME") "/.config/macros"))
                 "/k8s-metrics"))
;; A context name as a file name: letters, digits, `-` and `.` kept, rest `_`.
(define k8s--slug-chars
  (string->list "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-."))
(define (k8s--slug s)
  (list->string (map (lambda (c) (if (member c k8s--slug-chars) c #\_)) (string->list s))))
(define (k8s--store-file ctx)
  (string-append (k8s--store-dir) "/" (k8s--slug (if (equal? ctx "") "none" ctx)) ".tsv"))

(define (k8s--record->line r)
  (string-join (cons (number->string (car r))
                     (cons (cadr r) (map number->string (cddr r))))
               "\t"))
(define (k8s--line->record line)
  (let ((f (split-many line "\t")))
    (and (= (length f) 6)
         (let ((nums (map string->number (cons (car f) (cddr f)))))
           (and (not (member #f nums))
                (list (car nums) (cadr f) (nth nums 1) (nth nums 2) (nth nums 3) (nth nums 4)))))))

;; Drop readings older than the retention window.
(define (k8s--prune records now)
  (let ((cutoff (- now (k8s--retention-secs))))
    (filter (lambda (r) (>= (car r) cutoff)) records)))

;; Make `store` hold the current context's history (loading it from disk on
;; first use and after a context switch).
(define (k8s--store-sync!)
  (let ((ctx (k8s--st 'context)))
    (when (not (equal? ctx (k8s--st 'store-ctx)))
      (let* ((file (k8s--store-file ctx))
             (recs (if (file-exists? file)
                       (filter (lambda (r) r) (map k8s--line->record (k8s--lines (read-file file))))
                       '())))
        (k8s--st! 'store (k8s--prune recs (k8s--now)))
        (k8s--st! 'store-ctx ctx)))))

(define (k8s--store-save!)
  (write-file (k8s--store-file (k8s--st 'store-ctx))
              (string-append (string-join (map k8s--record->line (k8s--st 'store)) "\n") "\n")))

;; "45%" → 45.0 (kubectl top nodes' percentage columns), #f if not a number.
(define (k8s--parse-pct s)
  (k8s--num (if (ends-with? s "%") (k8s--strip-suffix s "%") s)))

;; One `kubectl top nodes` reading (NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%),
;; appended to the stored history, pruned, and saved. #f when it fails.
(define (k8s--sample-node-metrics!)
  (k8s--store-sync!)
  (let ((res (k8s--run-full (list "top" "nodes" "--no-headers"))))
    (and (equal? (car res) "0")
         (let* ((now (k8s--now))
                (fresh (filter (lambda (r) r)
                               (map (lambda (row)
                                      (let* ((f (k8s--fields row))
                                             (cpu (k8s--parse-cpu (k8s--nth-or f 1 "")))
                                             (cpu% (k8s--parse-pct (k8s--nth-or f 2 "")))
                                             (mem (k8s--parse-mem (k8s--nth-or f 3 "")))
                                             (mem% (k8s--parse-pct (k8s--nth-or f 4 ""))))
                                        (and cpu cpu% mem mem%
                                             (list now (k8s--nth-or f 0 "") cpu cpu% mem mem%))))
                                    (k8s--lines (cadr res))))))
           (when (not (null? fresh))
             (k8s--st! 'store (k8s--prune (append (k8s--st 'store) fresh) now))
             (k8s--store-save!))
           #t))))

;; The stored readings grouped by sample time: ((epoch records…) …), oldest first.
(define (k8s--by-epoch records)
  (let loop ((rs records) (cur #f) (acc '()) (out '()))
    (cond ((null? rs) (reverse (if cur (cons (cons cur (reverse acc)) out) out)))
          ((equal? (car (car rs)) cur) (loop (cdr rs) cur (cons (car rs) acc) out))
          (else (loop (cdr rs) (car (car rs)) (list (car rs))
                      (if cur (cons (cons cur (reverse acc)) out) out))))))

;; "2h 05m" / "14m" / "40s" for a span in seconds.
(define (k8s--fmt-span secs)
  (let* ((s (inexact->exact (round secs))) (h (quotient s 3600)) (m (quotient (remainder s 3600) 60)))
    (cond ((>= h 1) (string-append (number->string h) "h " (if (< m 10) "0" "") (number->string m) "m"))
          ((>= m 1) (string-append (number->string m) "m"))
          (else (string-append (number->string s) "s")))))

;; ── stored workload history ──
;; Pods come and go; their workloads (Deployment, StatefulSet, DaemonSet, Job…)
;; persist, so pod usage is stored per workload: at each sampler reading, the CPU
;; and memory summed over the workload's pods and the pod count (average per pod
;; = sum / count). Records are (epoch ns group cpu-sum mem-sum pods), in
;; <context>.workloads.tsv beside the node history, pruned the same way.
(define (k8s--wl-file ctx)
  (string-append (k8s--store-dir) "/" (k8s--slug (if (equal? ctx "") "none" ctx)) ".workloads.tsv"))

(define (k8s--wl->line r)
  (string-join (list (number->string (car r)) (cadr r) (nth r 2)
                     (number->string (nth r 3)) (number->string (nth r 4)) (number->string (nth r 5)))
               "\t"))
(define (k8s--line->wl line)
  (let ((f (split-many line "\t")))
    (and (= (length f) 6)
         (let ((t (string->number (car f))) (c (string->number (nth f 3)))
               (m (string->number (nth f 4))) (n (string->number (nth f 5))))
           (and t c m n (> n 0) (list t (cadr f) (nth f 2) c m n))))))

(define (k8s--wl-sync!)
  (let ((ctx (k8s--st 'context)))
    (when (not (equal? ctx (k8s--st 'wl-store-ctx)))
      (let* ((file (k8s--wl-file ctx))
             (recs (if (file-exists? file)
                       (filter (lambda (r) r) (map k8s--line->wl (k8s--lines (read-file file))))
                       '())))
        (k8s--st! 'wl-store (k8s--prune recs (k8s--now)))
        (k8s--st! 'wl-store-ctx ctx)
        (k8s--st! 'wl-recorded-at #f)))))

;; Fold the latest pod reading into per-workload records, once per reading.
(define (k8s--record-workloads!)
  (k8s--wl-sync!)
  (let ((at (k8s--st 'metrics-at)))
    (when (and (k8s--st 'metrics-ok) at (not (equal? at (k8s--st 'wl-recorded-at))))
      (let* ((gmap (k8s--pod-group-map))
             (sums (let loop ((ps (k8s--pods-now)) (h (hash)))
                     (if (null? ps)
                         h
                         (let* ((p (car ps))
                                (key (car p))
                                (ns (car (k8s--split-once key "/")))
                                (grp (let ((g (alist-ref gmap key))) (if g g "(no controller)")))
                                (k (string-append ns "\t" grp))
                                (cur (let ((c (hash-try-get h k))) (if c c (list 0.0 0.0 0)))))
                           (loop (cdr ps)
                                 (hash-insert h k (list (+ (car cur) (cadr p)) (+ (cadr cur) (nth p 2))
                                                        (+ (nth cur 2) 1))))))))
             (fresh (map (lambda (k)
                           (let ((parts (split-many k "\t")) (v (hash-try-get sums k)))
                             (list at (car parts) (cadr parts) (car v) (cadr v) (nth v 2))))
                         (hash-keys->list sums))))
        (k8s--st! 'wl-recorded-at at)
        (when (not (null? fresh))
          (k8s--st! 'wl-store (k8s--prune (append (k8s--st 'wl-store) fresh) (k8s--now)))
          (write-file (k8s--wl-file (k8s--st 'wl-store-ctx))
                      (string-append (string-join (map k8s--wl->line (k8s--st 'wl-store)) "\n") "\n")))))))

;; Workload records in the selected scope, labeled "group" (or "ns/group"
;; across all namespaces): an alist label -> records, oldest first.
(define (k8s--wl-in-scope)
  (let* ((all (k8s--st 'all-ns))
         (ns (k8s--st 'namespace))
         (recs (filter (lambda (r) (or all (equal? (cadr r) ns))) (k8s--st 'wl-store)))
         (label (lambda (r) (if all (string-append (cadr r) "/" (nth r 2)) (nth r 2)))))
    (map (lambda (l) (cons l (filter (lambda (r) (equal? (label r) l)) recs)))
         (k8s--uniq (map label recs)))))

;; Per-pod average CPU (millicores) / memory (MiB) of one workload record.
(define (k8s--wl-avg-cpu r) (/ (nth r 3) (nth r 5)))
(define (k8s--wl-avg-mem r) (/ (nth r 4) (nth r 5)))

;; `values` of timestamped records bucketed into `cols` equal slices of [t0, now]
;; (mean per bucket; #f where empty) — the shape a sparkline or heat row wants.
(define (k8s--bucket recs t0 now cols f)
  (let* ((span (max 1 (- now t0)))
         (acc (let loop ((rs recs) (h (hash)))
                (if (null? rs)
                    h
                    (let* ((r (car rs))
                           (b (min (- cols 1) (max 0 (inexact->exact (floor (* cols (/ (- (car r) t0) span)))))))
                           (cur (let ((c (hash-try-get h b))) (if c c (list 0.0 0)))))
                      (loop (cdr rs) (hash-insert h b (list (+ (car cur) (f r)) (+ (cadr cur) 1)))))))))
    (map (lambda (b) (let ((c (hash-try-get acc b))) (if c (/ (car c) (cadr c)) #f)))
         (range 0 cols))))

;; Workloads table: per workload, CPU and memory sparklines over the stored
;; window (average per pod), the latest averages, and the pod count.
(define (k8s--emit-workload-table groups t0 now)
  (let* ((cols 30)
         (w (apply max (cons 8 (map (lambda (g) (string-length (car g))) groups))))
         ;; Between readings the last value holds; before the first, blank.
         (spark (lambda (vals)
                  (let loop ((vs vals) (prev #f) (lead 0) (acc '()))
                    (cond ((null? vs)
                           (pad-right (string-append (make-string lead #\space)
                                                     (if (null? acc) "" (k8s--sparkline (reverse acc) 'min 0)))
                                      cols))
                          ((car vs) (loop (cdr vs) (car vs) lead (cons (car vs) acc)))
                          (prev (loop (cdr vs) prev lead (cons prev acc)))
                          (else (loop (cdr vs) prev (+ lead 1) acc)))))))
    (section-line (string-append "  " (pad-right "WORKLOAD" w) "  "
                                 (pad-right "CPU / pod" (+ cols 8)) (pad-right "MEMORY / pod" (+ cols 9)) "PODS")
                  "k8s-dim")
    (for-each
     (lambda (g)
       (let* ((recs (cdr g)) (now-r (last recs)))
         (k8s--line-with-segs
          (string-append "  " (pad-right (car g) w))
          (list (list "  " #f)
                (list (spark (k8s--bucket recs t0 now cols k8s--wl-avg-cpu)) "plot-series-0")
                (list (string-append " " (pad-right (k8s--fmt-cpu (k8s--wl-avg-cpu now-r)) 6) " ") "k8s-dim")
                (list (spark (k8s--bucket recs t0 now cols k8s--wl-avg-mem)) "plot-series-1")
                (list (string-append " " (pad-right (k8s--fmt-mem (k8s--wl-avg-mem now-r)) 7) " ") "k8s-dim")
                (list (number->string (nth now-r 5)) #f))
          #f)))
     groups)))

;; ── background sampler ──
;; Self-rearming timer: one node reading (stored) and one pod reading (for the
;; pod charts and the dashboard sparklines) per k8s-metrics-interval, while the
;; dashboard or metrics buffer is open. Redraws the metrics buffer after each.
(define (k8s--sampler-arm!)
  (when (not (k8s--st 'sampler-armed))
    (k8s--st! 'sampler-armed #t)
    (run-with-timer (* 1000 (k8s--metrics-interval)) "k8s--sample-tick")))
(define-command (k8s--sample-tick)
  (k8s--st! 'sampler-armed #f)
  (let ((metrics? (member "*k8s-metrics*" (buffer-names)))
        (dash? (member "*k8s-dashboard*" (buffer-names))))
    (when (or metrics? dash?)
      (k8s--resolve-context!)
      (k8s--sample-node-metrics!)
      (k8s--sample-pod-metrics!)
      (k8s--record-workloads!)
      (when metrics?
        (k8s--render-metrics (not (equal? (current-buffer) "*k8s-metrics*")) #f))
      (k8s--sampler-arm!))))

;; ── charts ──
;; Pod name as shown in charts: "ns/pod" across all namespaces, else just "pod".
(define (k8s--chart-pod-name key)
  (if (k8s--st 'all-ns) key (cadr (k8s--split-once key "/"))))
(define (k8s--split-once s sep)
  (let ((parts (split-many s sep)))
    (list (car parts) (string-join (cdr parts) sep))))

;; Newest (key cpu mem) per pod from the sampled history.
(define (k8s--pods-now)
  (let ((hist (k8s--st 'metrics)))
    (map (lambda (k) (let ((s (last (hash-try-get hist k)))) (list k (car s) (cadr s))))
         (hash-keys->list hist))))

;; The `n` heaviest pods by the reading at index `i` (1 = CPU, 2 = memory).
(define (k8s--top-pods n i)
  (k8s--take (sort (k8s--pods-now) (lambda (a b) (> (nth a i) (nth b i)))) n))

;; Emit a plot (from plot.scm) under a foldable heading, or a dim note.
(define (k8s--chart-section id title note plot)
  (section-open id title "k8s-section")
  (if plot
      ((k8s--plot-fn "plot-section-emit") plot)
      (section-line (string-append "    " note) "k8s-dim"))
  (section-close id)
  (section-line "" #f))

;; Pad labels to one width (plot-bars pads only within one call).
(define (k8s--pad-labels items)
  (let ((w (apply max (cons 0 (map (lambda (it) (string-length (car it))) items)))))
    (map (lambda (it) (cons (pad-right (car it) w) (cdr it))) items)))

;; A cluster total over time as (x y) points: x in minutes (or hours, for spans
;; over 3h) before now, so the axis reads "-120 … 0". Returns (points unit).
(define (k8s--series epochs now f)
  (let* ((span (if (null? epochs) 0 (- now (car (car epochs)))))
         (hours? (> span 10800))
         (scale (if hours? 3600.0 60.0)))
    (list (map (lambda (e) (list (/ (- (car e) now) scale) (f (cdr e)))) epochs)
          (if hours? "hours" "minutes"))))

;; Node CPU % as a heat matrix: the stored window split into *k8s-chart-columns*
;; equal time buckets, each the node's mean CPU % (blank where it has none).
;; One pass accumulating (sum count) per "node|bucket", so a day of readings
;; stays cheap to draw.
(define (k8s--node-heat records now)
  (let* ((names (sort (k8s--uniq (map cadr records)) string<?))
         (t0 (apply min (cons now (map car records))))
         (span (max 1 (- now t0)))
         (cols *k8s-chart-columns*)
         (key (lambda (name b) (string-append name "|" (number->string b))))
         (acc (let loop ((rs records) (h (hash)))
                (if (null? rs)
                    h
                    (let* ((r (car rs))
                           (b (min (- cols 1) (inexact->exact (floor (* cols (/ (- (car r) t0) span))))))
                           (k (key (cadr r) b))
                           (cur (let ((c (hash-try-get h k))) (if c c (list 0.0 0)))))
                      (loop (cdr rs) (hash-insert h k (list (+ (car cur) (nth r 3)) (+ (cadr cur) 1)))))))))
    (list names
          (map (lambda (name)
                 (map (lambda (b)
                        (let ((c (hash-try-get acc (key name b))))
                          (if c (/ (car c) (cadr c)) #f)))
                      (range 0 cols)))
               names))))

;; Pod health: counts per STATUS, each bar in its status color, plus the top
;; restarters. Built from `kubectl get pods`, so it works without metrics-server.
(define (k8s--emit-pod-health bars empty-note)
  (let* ((off  (if (k8s--st 'all-ns) 1 0))
         (rows (map k8s--fields
                    (k8s--lines (k8s--run (append (list "get" "pods" "--no-headers")
                                                  (k8s--get-ns-args #t))))))
         (statuses (map (lambda (f) (k8s--nth-or f (+ off 2) "?")) rows))
         (counts (map (lambda (st) (list st (length (filter (lambda (x) (equal? x st)) statuses))))
                      (k8s--uniq statuses)))
         (counts (sort counts (lambda (a b) (> (cadr a) (cadr b)))))
         (restarts (filter (lambda (r) (> (cadr r) 0))
                           (map (lambda (f)
                                  (list (let ((name (k8s--nth-or f off "")))
                                          (if (= off 1) (string-append (car f) "/" name) name))
                                        (let ((n (k8s--num (k8s--nth-or f (+ off 3) "0"))))
                                          (if n n 0))))
                                rows)))
         (restarts (k8s--take (sort restarts (lambda (a b) (> (cadr a) (cadr b)))) 5)))
    (section-open 'k8s-m-health (string-append "Pod health (" (number->string (length rows)) " pods)")
                  "k8s-section")
    (if (null? counts)
        (section-line (string-append "    " empty-note) "k8s-dim")
        (let ((mx (apply max (map cadr counts)))
              (emit (k8s--plot-fn "plot-section-emit")))
          ;; One plot-bars call per status so each bar takes its status color.
          (for-each (lambda (it)
                      (emit (bars (list it) 'width 30 'max mx
                                  'face (k8s--phase-face (string-trim (car it))))))
                    (k8s--pad-labels counts))
          (when (not (null? restarts))
            (section-line "" #f)
            (section-line "    Most restarts" "k8s-dim")
            (emit (bars restarts 'width 30 'face "k8s-warn")))))
    (section-close 'k8s-m-health)
    (section-line "" #f)))

;; Build the metrics buffer. `sample?` takes fresh node and pod readings first
;; (an explicit `r`); the background sampler passes #f after sampling itself.
(define (k8s--render-metrics quiet sample?)
  (let ((lines (k8s--plot-fn "plot-lines"))
        (bars  (k8s--plot-fn "plot-bars"))
        (heat  (k8s--plot-fn "plot-heatmap"))
        (histo (k8s--plot-fn "plot-histogram")))
    (if (not (and lines bars heat histo))
        (message "k8s-metrics needs an editor with plot.scm (text charts)")
        (begin
          (k8s--resolve-context!)
          (k8s--store-sync!)
          (when sample?
            (k8s--sample-node-metrics!)
            (k8s--sample-pod-metrics!))
          (k8s--record-workloads!)
          (k8s--sampler-arm!)
          (let* ((now (k8s--now))
                 (store (k8s--prune (k8s--st 'store) now))
                 (epochs (k8s--by-epoch store))
                 (latest (if (null? epochs) '() (cdr (last epochs))))
                 (span (if (null? epochs) 0 (- now (car (car epochs)))))
                 (ns-label (if (k8s--st 'all-ns) "<all>" (k8s--st 'namespace)))
                 (ok (k8s--st 'metrics-ok))
                 (no-pods (if (k8s--st 'all-ns)
                              "(no pods)"
                              (string-append "(no pods in namespace " ns-label
                                             " · A for all namespaces)")))
                 (pod-why (if ok no-pods "(needs metrics-server: `kubectl top pods` failed)"))
                 (node-why (cond ((null? epochs)
                                  "(no `kubectl top nodes` readings yet: needs metrics-server)")
                                 ((< (length epochs) 2)
                                  (string-append "(collecting: one reading every "
                                                 (number->string (k8s--metrics-interval)) "s)"))
                                 (else #f))))
            (section-begin)
            (section-line
             (string-append "Metrics · Context: " (let ((c (k8s--st 'context))) (if (equal? c "") "(none)" c))
                            "    Pods: " ns-label)
             "k8s-header")
            (section-line
             (string-append "  " (number->string (length epochs)) " readings over "
                            (k8s--fmt-span span) " · one every " (number->string (k8s--metrics-interval))
                            "s · kept " (k8s--fmt-span (k8s--retention-secs)))
             "k8s-dim")
            (section-line "  r sample now · A all namespaces · TAB fold · D dashboard · q quit" "k8s-dim")
            (section-line "" #f)
            ;; 1. Cluster usage over time: the sum over nodes at each reading.
            ;;    The y axis fits the data, so a trend isn't flattened against 0.
            (let ((cpu (k8s--series epochs now (lambda (rs) (/ (apply + (map (lambda (r) (nth r 2)) rs)) 1000.0))))
                  (mem (k8s--series epochs now (lambda (rs) (/ (apply + (map (lambda (r) (nth r 4)) rs)) 1024.0)))))
              (k8s--chart-section 'k8s-m-cpu
                (string-append "Cluster CPU (cores) · x: " (cadr cpu) " ago") node-why
                (and (not node-why) (lines (list (list "cpu" (car cpu))) 'width 60 'height 6 'x-max 0)))
              (k8s--chart-section 'k8s-m-mem
                (string-append "Cluster memory (GiB) · x: " (cadr mem) " ago") node-why
                (and (not node-why) (lines (list (list "mem" (car mem))) 'width 60 'height 6 'x-max 0))))
            ;; 2. Node utilization at the latest reading.
            (k8s--chart-section 'k8s-m-nodes "Node utilization (%) now · CPU, memory"
              "(no `kubectl top nodes` readings yet)"
              (and (not (null? latest))
                   (append
                    (bars (k8s--pad-labels (map (lambda (r) (list (string-append (cadr r) " cpu") (nth r 3))) latest))
                          'width 40 'max 100 'face "plot-series-0")
                    (bars (k8s--pad-labels (map (lambda (r) (list (string-append (cadr r) " mem") (nth r 5))) latest))
                          'width 40 'max 100 'face "plot-series-1"))))
            ;; 3. Node CPU over the stored window, bucketed into fixed columns.
            (let ((hm (if node-why #f (k8s--node-heat store now))))
              (k8s--chart-section 'k8s-m-heat
                (string-append "Node CPU (%) · last " (k8s--fmt-span span) ", oldest left") node-why
                (and hm (heat (cadr hm) 'row-labels (car hm) 'min 0 'max 100 'cell-width 1))))
            ;; Workloads (pod groups) over time: average per pod, the 5 heaviest
            ;; as line series, then every workload as a sparkline row.
            (let* ((groups (k8s--wl-in-scope))
                   (wl-epochs (k8s--uniq (map car (apply append (map cdr groups)))))
                   (wl-why (cond ((not ok) pod-why)
                                 ((null? groups) no-pods)
                                 ((< (length wl-epochs) 2)
                                  (string-append "(collecting: one reading every "
                                                 (number->string (k8s--metrics-interval)) "s)"))
                                 (else #f)))
                   (t0 (if (null? wl-epochs) now (apply min wl-epochs)))
                   (hours? (> (- now t0) 10800))
                   (scale (if hours? 3600.0 60.0))
                   (unit (if hours? "hours" "minutes"))
                   (top (lambda (f)
                          (k8s--take (sort groups (lambda (a b) (> (f (last (cdr a))) (f (last (cdr b))))))
                                     5)))
                   (series (lambda (f)
                             (map (lambda (g)
                                    (list (car g)
                                          (map (lambda (r) (list (/ (- (car r) now) scale) (f r))) (cdr g))))
                                  (top f)))))
              (k8s--chart-section 'k8s-m-wlcpu
                (string-append "Workload CPU per pod (millicores) · top 5 · x: " unit " ago") wl-why
                (and (not wl-why)
                     (lines (series k8s--wl-avg-cpu) 'width 60 'height 8 'x-max 0 'legend #t)))
              (k8s--chart-section 'k8s-m-wlmem
                (string-append "Workload memory per pod (MiB) · top 5 · x: " unit " ago") wl-why
                (and (not wl-why)
                     (lines (series k8s--wl-avg-mem) 'width 60 'height 8 'x-max 0 'legend #t)))
              (section-open 'k8s-m-wltable
                            (string-append "Workloads (" (number->string (length groups))
                                           ") · per pod, last " (k8s--fmt-span (- now t0)))
                            "k8s-section")
              (if (null? groups)
                  (section-line (string-append "    " (if ok no-pods pod-why)) "k8s-dim")
                  (k8s--emit-workload-table
                   (sort groups (lambda (a b) (> (k8s--wl-avg-cpu (last (cdr a)))
                                                 (k8s--wl-avg-cpu (last (cdr b))))))
                   t0 now))
              (section-close 'k8s-m-wltable)
              (section-line "" #f))
            ;; 4. Heaviest pods (latest pod reading, in the selected namespace).
            (let ((cpu-top (k8s--top-pods 8 1)) (mem-top (k8s--top-pods 8 2)))
              (k8s--chart-section 'k8s-m-topcpu "Top pods by CPU (millicores)" pod-why
                (and ok (not (null? cpu-top))
                     (bars (map (lambda (p) (list (k8s--chart-pod-name (car p)) (cadr p))) cpu-top)
                           'width 40 'face "plot-series-0")))
              (k8s--chart-section 'k8s-m-topmem "Top pods by memory (MiB)" pod-why
                (and ok (not (null? mem-top))
                     (bars (map (lambda (p) (list (k8s--chart-pod-name (car p)) (nth p 2))) mem-top)
                           'width 40 'face "plot-series-1"))))
            ;; 5. Memory distribution across pods.
            (let ((mems (map (lambda (p) (nth p 2)) (k8s--pods-now))))
              (k8s--chart-section 'k8s-m-dist "Pod memory distribution (MiB)" pod-why
                (and ok (>= (length mems) 2)
                     (histo mems 'bins 12 'height 6 'face "plot-series-1"))))
            ;; 6. Pod health (kubectl get pods; no metrics needed).
            (k8s--emit-pod-health bars no-pods))
          (if quiet
              (render-buffer-quiet "*k8s-metrics*" "k8s-metrics-mode" (section-text) (section-line-faces))
              (begin
                ;; In place: point's line and the scroll position are kept (no goto-line).
                (section-render "*k8s-metrics*" "k8s-metrics-mode")))
          (k8s--st! 'built "*k8s-metrics*")))))

(define-command (k8s-metrics)
  (k8s--resolve-context!)
  (when (not (k8s--st 'ns-resolved))
    (k8s--resolve-namespace!)
    (k8s--st! 'ns-resolved #t))
  (k8s--render-metrics #f #t))

;; A in the metrics buffer: toggle all namespaces and redraw the charts.
(define-command (k8s-metrics-toggle-all-namespaces)
  (k8s--st! 'all-ns (not (k8s--st 'all-ns)))
  (k8s--st! 'metrics (hash))   ; the pod readings were for the other scope
  (k8s--render-metrics #f #t))

;; Pods, grouped by owning workload. The `-o wide` rows give the display columns
;; (rich STATUS, restarts, node); a second custom-columns query resolves each
;; pod's group. Fold a group to hide its pods, fold "Pods" to hide everything.
(define (k8s--emit-pods)
  (k8s--sample-pod-metrics!)
  (let* ((off  (if (k8s--st 'all-ns) 1 0))
         (all  (k8s--lines (k8s--run (append (list "get" "pods" "-o" "wide")
                                             (k8s--get-ns-args #t)))))
         ;; With metrics, pad rows to one width so the appended columns line up
         ;; (kubectl doesn't pad its last column).
         (metrics? (and (k8s--st 'metrics-ok) (not (null? all))))
         (width  (if metrics? (apply max (map string-length all)) 0))
         (all    (if metrics? (map (lambda (r) (pad-right r width)) all) all))
         (header (cond ((null? all) "")
                       (metrics? (string-append (car all) (k8s--pod-metric-header)))
                       (else (car all))))
         (body   (if (null? all) '() (cdr all)))
         (gmap (k8s--pod-group-map))
         (recs (map (lambda (row)
                      (let* ((f (k8s--fields row))
                             (name (k8s--nth-or f off ""))
                             (ns   (if (= off 1) (k8s--nth-or f 0 "") (k8s--st 'namespace)))
                             (key  (string-append ns "/" name))
                             (grp  (let ((g (alist-ref gmap key))) (if g g "(no controller)")))
                             (face (k8s--phase-face (k8s--nth-or f (+ 2 off) ""))))
                        (list grp row name ns face "pod" (k8s--pod-metric-segs key))))
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
     (string-append "  r refresh · TAB fold · d describe · l logs · s shell/scale · S full shell · "
                    "y yaml · x delete · N ns · A all-ns · C ctx · a auto · M metrics · ? more · q quit")
     "k8s-dim")
    (section-line "" #f)))

;; Rebuild the dashboard from live kubectl queries. `quiet` updates the buffer
;; IN PLACE without stealing focus (background auto-refresh while the user is in
;; another buffer) — like magit's quiet refresh, it skips fold/accent overlays,
;; which re-apply on the next in-front render. The interactive path preserves
;; point and re-applies folds.
(define (k8s--render quiet)
  (let ()
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
          ;; An in-place render keeps point's line and the scroll position on
          ;; its own; a goto-line here would scroll the view back to point.
          (section-render "*k8s-dashboard*" "k8s-mode")))
    (k8s--st! 'built "*k8s-dashboard*")))

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
  (k8s-refresh)
  ;; Keep the metrics history growing while the dashboard is open (no-op on
  ;; editors without plot.scm).
  (when (k8s--plot-fn "plot-lines") (k8s--sampler-arm!)))

;; ── navigation / fold ─────────────────────────────────────────────────────────
;; lib-section keeps ONE set of sections — the last buffer built. With both the
;; dashboard and the metrics buffer open, rebuild this one first if the other was
;; built since (a background refresh), or TAB would fold by the wrong layout.
(define-command (k8s-toggle-fold)
  (let ((buf (current-buffer)))
    (when (not (equal? buf (k8s--st 'built)))
      (cond ((equal? buf "*k8s-dashboard*") (k8s--render #f))
            ((equal? buf "*k8s-metrics*") (k8s--render-metrics #f #f))))
    (section-toggle-at-point)))

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
;; `s`: split the dashboard window in half and run an interactive shell inside the
;; pod in the new bottom pane. Focus follows the `k8s-shell-focus` option (the
;; terminal by default, so you can type). `S`: the same shell, full-window (it
;; replaces the dashboard in this window; `C-x b` goes back).
;;
;; A terminal sends almost every key to the shell. What still reaches the editor:
;; `C-x` (`C-x o` other pane, `C-x 1` only this pane, `C-x k` kill), your evil
;; leader chords via the ALT leader (`M-SPC n o` = your `SPC n o`), and any chord
;; in the `terminal-passthrough-keys` option. When the shell exits, its pane and
;; buffer close on their own (see k8s--on-terminal-exit).
(define k8s--shell-prefix "*k8s-shell:")
(define (k8s--open-shell pod ns full)
  (let ((sh (k8s--shell))
        (stay (and (not full) (k8s--shell-focus-dashboard?))))
    (when (not full)
      (split-window-below)                   ; half-height pane across the bottom
      (other-window))                        ; the terminal opens in the new pane
    (make-terminal (string-append k8s--shell-prefix pod "*") *k8s-command*
                   (list "exec" "-it" pod "-n" ns "--" sh)
                   "")                       ; "" → the active buffer's directory
    (when stay (other-window))               ; back to the dashboard pane
    (message (string-append "shell → " pod " (" ns ") : " sh
                            (if stay "  ·  C-x o to enter it" "")))))
(define-command (k8s-shell)
  (let ((r (k8s--resource-at)))
    (when (k8s--require-kind r "pod" "pod to open a shell")
      (k8s--open-shell (nth r 2) (nth r 3) #f))))
(define-command (k8s-shell-full)
  (let ((r (k8s--resource-at)))
    (when (k8s--require-kind r "pod" "pod to open a shell")
      (k8s--open-shell (nth r 2) (nth r 3) #t))))

;; terminal-exit-hook handler (called with the dead terminal's buffer name): close
;; a pod shell's pane — unless it's the only window — and kill its buffer, so an
;; `exit` leaves you back on the dashboard instead of in a dead split.
(define (k8s--on-terminal-exit name)
  (when (and (starts-with? name k8s--shell-prefix)
             (not (k8s--shell-keep-on-exit?)))
    (let ((w (get-buffer-window name)))
      (when (and (>= w 0) (> (length (window-list)) 1))
        (select-window w)
        (delete-window)))
    (kill-buffer-named name)))
(add-hook "terminal-exit-hook" 'k8s--on-terminal-exit)

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
    (cond ((and r (equal? (nth r 1) "pod"))        (k8s--open-shell (nth r 2) (nth r 3) #f))
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
                    (list "shift-s" "Shell (full window)" 'k8s-shell-full)
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
                    (list "shift-m" "Metrics charts" 'k8s-metrics)
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
(define-key "k8s-mode" "shift-s" 'k8s-shell-full)   ; S — pod shell, full window
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
(define-key "k8s-mode" "shift-m" 'k8s-metrics)     ; M — the metrics charts

;; Metrics buffer: r samples now, D jumps back to the dashboard.
(set-option "line-numbers:k8s-metrics-mode" "false")
(define-command (k8s-metrics-refresh) (k8s--render-metrics #f #t))
(define-key "k8s-metrics-mode" "r" 'k8s-metrics-refresh)
(define-key "k8s-metrics-mode" "g" 'k8s-metrics-refresh)
(define-key "k8s-metrics-mode" "tab" 'k8s-toggle-fold)
(define-key "k8s-metrics-mode" "enter" 'k8s-toggle-fold)
(define-key "k8s-metrics-mode" "shift-a" 'k8s-metrics-toggle-all-namespaces)
(define-key "k8s-metrics-mode" "shift-d" 'k8s-dashboard)
(define-key "k8s-metrics-mode" "n" 'next-line)
(define-key "k8s-metrics-mode" "p" 'previous-line)
(define-key "k8s-metrics-mode" "q" 'kill-buffer)

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
;; Emacs, where the overlays aren't consulted. (Arrow keys work anyway; under
;; plain Emacs n/p move by line.)

;; Status buffer: motion + search only, so the letter action keys (d/l/y/s/x/a/r)
;; stay free — matching magit's evil-collection. `g` becomes a prefix under
;; evil/helix (`g g` top, `g r` refresh — evil-collection's convention); `r` still
;; refreshes on one key. `n` repeats a `/` search here (Emacs keeps n/p = lines);
;; `N` stays the namespace picker.
;;
;; Your own evil LEADER chords (`evil-leader-set` in init.scm) work in this buffer
;; too — the editor consults its leader keymap for special buffers, after this
;; overlay — so e.g. `SPC n o` runs `delete-other-windows` here.
(define (k8s--bind-status-motion km)
  (define-key km "j" 'next-line)
  (define-key km "k" 'previous-line)
  (define-key km "g g" 'evil-goto-first-line)
  (define-key km "g r" 'k8s-refresh)
  (define-key km "shift-g" 'evil-goto-last-line)
  (define-key km "ctrl-d" 'evil-scroll-down)
  (define-key km "ctrl-u" 'evil-scroll-up)
  (define-key km "/" 'evil-search-forward)
  (define-key km "n" 'evil-search-next))
(k8s--bind-status-motion "evil-normal:k8s-mode")
(k8s--bind-status-motion "helix-normal:k8s-mode")
(k8s--bind-status-motion "evil-normal:k8s-metrics-mode")
(k8s--bind-status-motion "helix-normal:k8s-metrics-mode")
;; `g r` there refreshes the charts, not the dashboard.
(define-key "evil-normal:k8s-metrics-mode" "g r" 'k8s-metrics-refresh)
(define-key "helix-normal:k8s-metrics-mode" "g r" 'k8s-metrics-refresh)

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
  (define-key km "ctrl-u" 'evil-scroll-up)
  (define-key km "/" 'evil-search-forward)
  (define-key km "?" 'evil-search-backward)
  (define-key km "n" 'evil-search-next)
  (define-key km "shift-n" 'evil-search-previous))
(k8s--bind-readonly-motion "evil-normal:k8s-detail-mode")
(k8s--bind-readonly-motion "helix-normal:k8s-detail-mode")
