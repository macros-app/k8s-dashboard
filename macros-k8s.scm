;;; macros-k8s — a Kubernetes dashboard for the macros editor, in Steel.
;;;
;;; A magit-style porcelain for `kubectl`. It sits on the same editor primitives
;;; magit.scm / macros-jj use — the Rust core knows nothing about k8s:
;;;   * `make-process` — the refresh runs its kubectl queries IN PARALLEL, each
;;;     writing to a temp file; the dashboard redraws once they've all exited
;;;   * `string->jsexpr` — resources are fetched as `-o json` and parsed once
;;;   * `call-process` / `call-process-full` — one-shot actions (describe, logs…)
;;;   * lib-section (`section-open`/`section-line`/`section-render`) — foldable,
;;;     navigable read-only status buffer with persistent fold state
;;;   * lib-plot / `textplot-sparkline` — usage sparklines and the trend chart
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
;;; A refresh is FETCH (async, parallel kubectl → `'data`) then RENDER (pure, from
;;; `'data`). Expanding a pod's containers or a job's earlier runs re-renders from
;;; the cached data without touching the cluster.
;;;
;;;   M-x k8s-dashboard     open the dashboard for the current context (bind it
;;;   yourself if you want a key — this package adds no global bindings).
;;;
;;; Self-contained apart from lib-section, lib-transient and lib-plot (all ship
;;; with the editor). `kubectl` must be on PATH — override with the *k8s-command*
;;; default (see the README config caveat). `kubectl top` (metrics-server) is
;;; optional: without it the usage columns, sparklines and trend chart are omitted.

;; ── configuration ────────────────────────────────────────────────────────────
(define *k8s-command* "kubectl")     ; the kubectl executable
(define *k8s-log-tail* 500)          ; lines fetched by the logs (l) command
(define *k8s-auto-refresh-ms* 5000)  ; poll interval when auto-refresh is on
(define *k8s-history* 40)            ; usage samples kept for sparklines / trends
(define *k8s-max-events* 15)         ; most recent Warning events shown

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
(set-face "k8s-accent"  "#66d9ef")   ; sparklines

;; ── state ─────────────────────────────────────────────────────────────────────
(define k8s-state
  (hash
   'context     ""    ; current kube context (resolved each refresh)
   'namespace   "default"
   'ns-resolved #f    ; have we read the context's default namespace yet?
   'all-ns      #f    ; show resources across ALL namespaces (kubectl -A)?
   'linemap     '()   ; (line kind name ns [container expand-key]) per rendered line
   'auto        #f    ; auto-refresh enabled?
   'timer-armed #f    ; is a poll timer currently scheduled?
   'confirm     #f    ; pending destructive-op closure (y-or-n-p)
   'data        #f    ; the last fetch, parsed (see k8s--ingest); #f = never fetched
   'pending     '()   ; fetch keys still running
   'results     #f    ; key -> (exit-code stdout stderr) for the fetch in flight
   'fetch-start 0     ; ms timestamp the in-flight fetch began
   'queued      #f    ; a refresh was requested while one was in flight
   'hist        #f    ; usage history (k8s--update-hist!), key -> list of numbers
   'expanded    '()   ; "pod:ns/name" / "grp:id" keys the user expanded with TAB
   'now         0     ; epoch seconds, fixed per render so every AGE agrees
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
  (if (or (<= n 0) (null? lst)) '() (cons (car lst) (k8s--take (cdr lst) (- n 1)))))
;; Drop the first n elements.
(define (k8s--drop lst n)
  (if (or (<= n 0) (null? lst)) lst (k8s--drop (cdr lst) (- n 1))))
(define (k8s--last-n lst n)
  (let ((len (length lst))) (if (>= n len) lst (k8s--drop lst (- len n)))))
;; Distinct list of `lst`, first-seen order preserved.
(define (k8s--uniq lst)
  (let loop ((l lst) (seen '()) (acc '()))
    (cond ((null? l) (reverse acc))
          ((member (car l) seen) (loop (cdr l) seen acc))
          (else (loop (cdr l) (cons (car l) seen) (cons (car l) acc))))))
(define (k8s--sum lst) (foldl + 0 lst))
;; Pairs (a . b) of two equal-length lists (Steel's map/for-each take one list).
(define (k8s--zip as bs)
  (if (or (null? as) (null? bs)) '() (cons (cons (car as) (car bs)) (k8s--zip (cdr as) (cdr bs)))))
(define (k8s--any pred lst)
  (cond ((null? lst) #f) ((pred (car lst)) #t) (else (k8s--any pred (cdr lst)))))
(define (k8s--all pred lst)
  (cond ((null? lst) #t) ((pred (car lst)) (k8s--all pred (cdr lst))) (else #f)))
(define (k8s--str n) (number->string n))
;; Drop the last `-`-separated segment (a ReplicaSet's name is
;; "<deployment>-<hash>", so this recovers the Deployment).
(define (k8s--strip-last-segment s)
  (let ((parts (split-many s "-")))
    (if (> (length parts) 1)
        (string-join (k8s--take parts (- (length parts) 1)) "-")
        s)))
(define (k8s--last-segment s)
  (let ((parts (split-many s "-"))) (if (null? parts) s (last parts))))
(define (k8s--digits? s)
  (and (> (string-length s) 0)
       (foldl (lambda (c ok) (and ok (member c (string->list "0123456789")) #t))
              #t (string->list s))))
;; Integer from a token like "(42%)", "68m" or "(9" — #f when it has no digits.
(define (k8s--int-of s)
  (let ((d (list->string (filter (lambda (c) (member c (string->list "0123456789")))
                                 (string->list s)))))
    (if (equal? d "") #f (string->number d))))
(define (k8s--now-ms) (string->number (current-time "%s%3f")))
(define (k8s--now) (string->number (current-time "%s")))
;; "a, b, +3 more" — at most `n` items of a string list.
(define (k8s--join-some lst n)
  (cond ((null? lst) "")
        ((<= (length lst) n) (string-join lst ","))
        (else (string-append (string-join (k8s--take lst n) ",")
                             ",+" (k8s--str (- (length lst) n))))))

;; Display width is CHARACTERS (string-length); overlay offsets are BYTES
;; (utf8-length) — the block glyphs are 3 bytes but one column.
(define (k8s--repeat s n) (if (<= n 0) "" (string-append s (k8s--repeat s (- n 1)))))
(define (k8s--pad-right s n) (string-append s (k8s--repeat " " (- n (string-length s)))))
(define (k8s--pad-left s n) (string-append (k8s--repeat " " (- n (string-length s))) s))

;; ── JSON access ───────────────────────────────────────────────────────────────
;; `string->jsexpr` gives hashes keyed by symbol, lists for arrays, floats for
;; every number and #<void> for null. (k8s--j obj 'a 'b 0 'c) walks a path and
;; returns #f for anything missing or null.
(define (k8s--j obj . path)
  (let loop ((o obj) (p path))
    (cond ((or (not o) (void? o)) #f)
          ((null? p) o)
          ((and (symbol? (car p)) (hash? o)) (loop (hash-try-get o (car p)) (cdr p)))
          ((and (integer? (car p)) (list? o) (< (car p) (length o)))
           (loop (list-ref o (car p)) (cdr p)))
          (else #f))))
(define (k8s--jl obj . path) (let ((v (apply k8s--j (cons obj path)))) (if (list? v) v '())))
(define (k8s--js obj . path) (let ((v (apply k8s--j (cons obj path)))) (if (string? v) v "")))
(define (k8s--ji obj . path)
  (let ((v (apply k8s--j (cons obj path)))) (if (number? v) (exact (round v)) 0)))
(define (k8s--name o) (k8s--js o 'metadata 'name))
(define (k8s--ns-of o) (k8s--js o 'metadata 'namespace))
(define (k8s--label o key) (k8s--j o 'metadata 'labels (string->symbol key)))
(define (k8s--parse-json s)
  (if (starts-with? (trim-start s) "{")
      (with-handler (lambda (e) #f) (string->jsexpr s))
      #f))
;; Sort by name — namespace first in all-namespaces mode, so each ns stays together.
(define (k8s--sort-key o) (string-append (if (k8s--st 'all-ns) (string-append (k8s--ns-of o) "/") "")
                                         (k8s--name o)))
(define (k8s--by-name lst) (sort lst (lambda (a b) (string<? (k8s--sort-key a) (k8s--sort-key b)))))

;; ── time ──────────────────────────────────────────────────────────────────────
;; Kubernetes timestamps are RFC 3339 in UTC ("2026-10-11T09:30:00Z").
(define (k8s--days-from-civil y m d)
  (let* ((y   (if (<= m 2) (- y 1) y))
         (era (quotient y 400))
         (yoe (- y (* era 400)))
         (mp  (if (> m 2) (- m 3) (+ m 9)))
         (doy (+ (quotient (+ (* 153 mp) 2) 5) (- d 1)))
         (doe (+ (* yoe 365) (quotient yoe 4) (- (quotient yoe 100)) doy)))
    (+ (* era 146097) doe -719468)))
(define (k8s--epoch ts)
  (if (and (string? ts) (>= (string-length ts) 19))
      (let ((y  (string->number (substring ts 0 4)))  (mo (string->number (substring ts 5 7)))
            (d  (string->number (substring ts 8 10))) (h  (string->number (substring ts 11 13)))
            (mi (string->number (substring ts 14 16))) (s (string->number (substring ts 17 19))))
        (if (and y mo d h mi s)
            (+ (* 86400 (k8s--days-from-civil y mo d)) (* 3600 h) (* 60 mi) s)
            #f))
      #f))
;; kubectl's HumanDuration (the AGE column format).
(define (k8s--human secs)
  (let* ((s (max 0 secs)) (m (quotient s 60)) (h (quotient s 3600)) (d (quotient s 86400))
         (y (quotient d 365))
         (two (lambda (a ua b ub) (if (= b 0) (string-append (k8s--str a) ua)
                                      (string-append (k8s--str a) ua (k8s--str b) ub)))))
    (cond ((< s 120)            (string-append (k8s--str s) "s"))
          ((< m 10)             (two m "m" (remainder s 60) "s"))
          ((< h 3)              (string-append (k8s--str m) "m"))
          ((< h 8)              (two h "h" (remainder m 60) "m"))
          ((< h 48)             (string-append (k8s--str h) "h"))
          ((< h 192)            (two d "d" (remainder h 24) "h"))
          ((< d 730)            (string-append (k8s--str d) "d"))
          ((< y 8)              (two y "y" (remainder d 365) "d"))
          (else                 (string-append (k8s--str y) "y")))))
(define (k8s--since ts)
  (let ((e (k8s--epoch ts))) (if e (k8s--human (- (k8s--st 'now) e)) "-")))
(define (k8s--age o) (k8s--since (k8s--js o 'metadata 'creationTimestamp)))
(define (k8s--created o) (or (k8s--epoch (k8s--js o 'metadata 'creationTimestamp)) 0))

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
(define (k8s--tmpdir)
  (let ((t (getenv "TMPDIR")))
    (cond ((equal? t "") "/tmp")
          ((ends-with? t "/") (substring t 0 (- (string-length t) 1)))
          (else t))))

;; ── async fetch ───────────────────────────────────────────────────────────────
;; One refresh = these kubectl queries, spawned together via make-process. Each
;; runs under `sh` so its stdout/stderr land in temp files (make-process would
;; otherwise call back once per LINE — thousands of calls for a JSON dump); the
;; per-key exit callback reads them back, and the last one to finish ingests
;; and renders. `kubectl top` failing (no metrics-server) just drops usage.
(define k8s--fetch-keys '(nodes pack res tnodes tpods events))
(define k8s--res-kinds
  "deployments,statefulsets,daemonsets,hpa,services,pods,cronjobs,jobs,ingresses,pvc,endpointslices")
(define (k8s--fetch-args key)
  (cond ((eq? key 'nodes)  (list "get" "nodes" "-o" "json"))
        ((eq? key 'pack)   (list "describe" "nodes"))
        ((eq? key 'res)    (append (list "get" k8s--res-kinds "-o" "json") (k8s--get-ns-args #t)))
        ((eq? key 'tnodes) (list "top" "nodes" "--no-headers"))
        ((eq? key 'tpods)  (append (list "top" "pods" "--no-headers") (k8s--get-ns-args #t)))
        (else (append (list "get" "events" "--field-selector" "type=Warning"
                            "--sort-by=.lastTimestamp")
                      (k8s--get-ns-args #t)))))
(define k8s--fetch-script
  "out=$1; shift; mkdir -p \"${out%/*}\"; \"$@\" >\"$out\" 2>\"$out.err\"")
(define (k8s--fetch-path key)
  (string-append (k8s--tmpdir) "/macros-k8s/fetch-" (symbol->string key)))

;; make-process callbacks are global names called with just the line / exit
;; code, so each key gets its own exit callback.
(define (k8s--noop line) #f)
(define (k8s--done-nodes code)  (k8s--fetch-done 'nodes code))
(define (k8s--done-pack code)   (k8s--fetch-done 'pack code))
(define (k8s--done-res code)    (k8s--fetch-done 'res code))
(define (k8s--done-tnodes code) (k8s--fetch-done 'tnodes code))
(define (k8s--done-tpods code)  (k8s--fetch-done 'tpods code))
(define (k8s--done-events code) (k8s--fetch-done 'events code))
(define (k8s--done-callback key)
  (string->symbol (string-append "k8s--done-" (symbol->string key))))

;; In flight (and not wedged: a fetch older than 30s is presumed lost).
(define (k8s--fetch-busy?)
  (and (not (null? (k8s--st 'pending)))
       (< (- (k8s--now-ms) (k8s--st 'fetch-start)) 30000)))
(define (k8s--fetch)
  (if (k8s--fetch-busy?)
      (k8s--st! 'queued #t)
      (begin
        (k8s--resolve-context!)
        (k8s--st! 'pending k8s--fetch-keys)
        (k8s--st! 'results (hash))
        (k8s--st! 'fetch-start (k8s--now-ms))
        (for-each
         (lambda (key)
           (make-process "/bin/sh"
                         (append (list "-c" k8s--fetch-script "sh" (k8s--fetch-path key)
                                       *k8s-command*)
                                 (k8s--fetch-args key))
                         'k8s--noop (k8s--done-callback key)))
         k8s--fetch-keys))))
(define (k8s--fetch-done key code)
  (when (member key (k8s--st 'pending))
    (let ((path (k8s--fetch-path key)))
      (k8s--st! 'results (hash-insert (k8s--st 'results) key
                                      (list code (read-file path)
                                            (read-file (string-append path ".err"))))))
    (k8s--st! 'pending (filter (lambda (k) (not (eq? k key))) (k8s--st 'pending)))
    (when (null? (k8s--st 'pending)) (k8s--finish-fetch))))
(define (k8s--finish-fetch)
  (k8s--st! 'data (with-handler
                   (lambda (e) (message (string-append "k8s: " (error-object-message e)))
                               (k8s--st 'data))
                   (k8s--ingest (- (k8s--now-ms) (k8s--st 'fetch-start)))))
  (when (member "*k8s-dashboard*" (buffer-names))
    (k8s--render-data (not (equal? (current-buffer) "*k8s-dashboard*"))))
  (when (k8s--st 'queued)
    (k8s--st! 'queued #f)
    (k8s--fetch)))

;; ── ingest (fetch results → 'data) ────────────────────────────────────────────
(define (k8s--result key) (hash-try-get (k8s--st 'results) key))
(define (k8s--out key) (let ((r (k8s--result key))) (if r (nth r 1) "")))
(define (k8s--err-line key)
  (let* ((r (k8s--result key))
         (ls (if r (filter (lambda (l) (not (starts-with? l "Warning:"))) (k8s--lines (nth r 2)))
                 '())))
    (if (null? ls) "no output" (car ls))))
(define (k8s--failed? key) (let ((r (k8s--result key))) (and r (not (equal? (car r) "0")))))

;; `kubectl top nodes`: name -> (cpu% mem%).
(define (k8s--parse-top-nodes s)
  (map (lambda (ln)
         (let ((f (k8s--fields ln)))
           (cons (k8s--nth-or f 0 "")
                 (list (k8s--int-of (k8s--nth-or f 2 "")) (k8s--int-of (k8s--nth-or f 4 ""))))))
       (filter (lambda (ln) (>= (length (k8s--fields ln)) 5)) (k8s--lines s))))
;; CPU quantity → millicores ("68m" → 68, "2" → 2000).
(define (k8s--cpu-m s)
  (let ((n (k8s--int-of s)))
    (cond ((not n) #f) ((ends-with? s "m") n) (else (* 1000 n)))))
;; `kubectl top pods`: "ns/name" -> (cpu-millicores mem-string).
(define (k8s--parse-top-pods s)
  (let ((all (k8s--st 'all-ns)) (ns0 (k8s--st 'namespace)))
    (map (lambda (ln)
           (let* ((f (k8s--fields ln)) (o (if all 1 0)))
             (cons (string-append (if all (k8s--nth-or f 0 "") ns0) "/" (k8s--nth-or f o ""))
                   (list (k8s--cpu-m (k8s--nth-or f (+ o 1) "")) (k8s--nth-or f (+ o 2) "-")))))
         (filter (lambda (ln) (>= (length (k8s--fields ln)) 3)) (k8s--lines s)))))

;; How full each node is, as the scheduler sees it: CPU / memory REQUESTS as a
;; percent of allocatable, plus pod count vs the allocatable pod limit. Parsed
;; from `kubectl describe nodes` (its "Allocated resources" block already carries
;; the percentages), so no metrics-server needed.
;; node-name -> (cpu% mem% pods pods-max), any of which may be #f.
(define (k8s--node-pack-map text)
  (let loop ((ls (k8s--lines text))
             (name #f) (cpu #f) (mem #f) (pods #f) (pmax #f) (acc '()))
    (let ((flush (lambda () (if name (cons (cons name (list cpu mem pods pmax)) acc) acc))))
      (if (null? ls)
          (reverse (flush))
          (let* ((f  (k8s--fields (car ls)))
                 (f0 (k8s--nth-or f 0 ""))
                 (f2 (k8s--nth-or f 2 "")))
            (cond
             ((equal? f0 "Name:")
              (loop (cdr ls) (k8s--nth-or f 1 #f) #f #f #f #f (flush)))
             ;; Allocated resources rows: `cpu  850m (42%)  100m (5%)` (no colon,
             ;; unlike the Capacity/Allocatable `cpu: 4` rows).
             ((and (equal? f0 "cpu") (string-contains? f2 "%"))
              (loop (cdr ls) name (k8s--int-of f2) mem pods pmax acc))
             ((and (equal? f0 "memory") (string-contains? f2 "%"))
              (loop (cdr ls) name cpu (k8s--int-of f2) pods pmax acc))
             ;; `Non-terminated Pods:  (9 in total)`
             ((and (equal? f0 "Non-terminated") (equal? (k8s--nth-or f 1 "") "Pods:"))
              (loop (cdr ls) name cpu mem (k8s--int-of f2) pmax acc))
             ;; `pods: 110` — Allocatable follows Capacity, so the last one wins.
             ((equal? f0 "pods:")
              (loop (cdr ls) name cpu mem pods (k8s--int-of (k8s--nth-or f 1 "")) acc))
             (else (loop (cdr ls) name cpu mem pods pmax acc))))))))

;; Usage history for the sparklines and trend chart: one sample per refresh,
;; at most *k8s-history* per key. Keys not seen this round (deleted pods) drop.
(define (k8s--hist key)
  (let ((h (k8s--st 'hist))) (or (and h (hash-try-get h key)) '())))
(define (k8s--hist-push h key v)
  (if v (hash-insert h key (k8s--last-n (append (k8s--hist key) (list v)) *k8s-history*)) h))
(define (k8s--update-hist! tnodes tpods)
  (let* ((h (foldl (lambda (n h)
                     (k8s--hist-push (k8s--hist-push h (string-append "cpu:" (car n)) (nth n 1))
                                     (string-append "mem:" (car n)) (nth n 2)))
                   (hash) tnodes))
         (h (foldl (lambda (p h) (k8s--hist-push h (string-append "pod:" (car p)) (nth p 1)))
                   h tpods))
         (cpus (filter number? (map (lambda (n) (nth n 1)) tnodes)))
         (mems (filter number? (map (lambda (n) (nth n 2)) tnodes)))
         (avg  (lambda (l) (if (null? l) #f (quotient (k8s--sum l) (length l)))))
         ;; The cluster trend survives a refresh with no metrics (keeps its samples).
         (h (if (null? cpus)
                (hash-insert (hash-insert h "cluster-cpu" (k8s--hist "cluster-cpu"))
                             "cluster-mem" (k8s--hist "cluster-mem"))
                (k8s--hist-push (k8s--hist-push h "cluster-cpu" (avg cpus))
                                "cluster-mem" (avg mems)))))
    (k8s--st! 'hist h)))

(define (k8s--ingest took)
  (let* ((nodes-j (k8s--parse-json (k8s--out 'nodes)))
         (res-j   (k8s--parse-json (k8s--out 'res)))
         (tnodes  (k8s--parse-top-nodes (k8s--out 'tnodes)))
         (tpods   (k8s--parse-top-pods (k8s--out 'tpods)))
         (errs    (append (if nodes-j '() (list (string-append "nodes: " (k8s--err-line 'nodes))))
                          (cond ((not res-j) (list (string-append "resources: " (k8s--err-line 'res))))
                                ((k8s--failed? 'res) (list (string-append "partial: " (k8s--err-line 'res))))
                                (else '())))))
    (k8s--update-hist! tnodes tpods)
    (hash 'nodes  (if nodes-j (k8s--jl nodes-j 'items) '())
          'items  (if res-j (k8s--jl res-j 'items) '())
          'pack   (k8s--node-pack-map (k8s--out 'pack))
          'tnodes tnodes
          'tpods  tpods
          'events (k8s--lines (k8s--out 'events))
          'errors errs
          'at     (current-time "%H:%M:%S")
          'took   took)))

;; ── status colors ─────────────────────────────────────────────────────────────
(define (k8s--errorish? s)
  (or (string-contains? s "Error") (string-contains? s "CrashLoop")
      (string-contains? s "BackOff") (string-contains? s "OOM")
      (string-contains? s "Evicted") (string-contains? s "Failed")
      (string-contains? s "ImagePull") (string-contains? s "InvalidImageName")
      (string-contains? s "NotReady") (string-contains? s "ExitCode")
      (string-contains? s "Signal")))
;; Pod phase / STATUS column.
(define (k8s--phase-face s)
  (cond ((member s (list "Running" "Completed" "Succeeded")) "k8s-ok")
        ((k8s--errorish? s) "k8s-err")
        ((or (member s (list "Pending" "ContainerCreating" "PodInitializing" "Terminating"))
             (starts-with? s "Init:")) "k8s-warn")
        (else "k8s-dim")))
;; The most severe face in a set (for a group heading summarizing its pods).
(define (k8s--worst-face faces)
  (cond ((member "k8s-err" faces)  "k8s-err")
        ((member "k8s-warn" faces) "k8s-warn")
        ((member "k8s-ok" faces)   "k8s-ok")
        (else                      "k8s-dim")))
;; Green with room to spare, yellow getting full, red (nearly) full.
(define (k8s--pack-face pct)
  (cond ((>= pct 90) "k8s-err") ((>= pct 70) "k8s-warn") (else "k8s-ok")))

;; ── tables ────────────────────────────────────────────────────────────────────
;; A cell is a string or (text accents), accents being (start end face) BYTE
;; ranges relative to the text. k8s--table pads columns to a common width (three
;; spaces apart, like kubectl) → (header-text rows), each row (text accents)
;; with the accents shifted to the row.
(define (k8s--cell c) (if (string? c) (list c '()) c))
(define (k8s--shift-accents accs off)
  (map (lambda (x) (list (+ off (nth x 0)) (+ off (nth x 1)) (nth x 2))) accs))
(define (k8s--join-cells cells widths)
  (let loop ((cs cells) (ws widths) (text "") (accs '()))
    (if (null? cs)
        (list text accs)
        (let* ((c   (car cs))
               (t   (if (null? (cdr cs)) (car c) (k8s--pad-right (car c) (+ (car ws) 3))))
               (off (utf8-length text)))
          (loop (cdr cs) (cdr ws) (string-append text t)
                (append accs (k8s--shift-accents (cadr c) off)))))))
(define (k8s--table header rows)
  (let* ((rows* (map (lambda (r) (map k8s--cell r)) rows))
         (widths (let loop ((i 0) (acc '()))
                   (if (= i (length header))
                       (reverse acc)
                       (loop (+ i 1)
                             (cons (foldl (lambda (r w)
                                            (max w (string-length (car (k8s--nth-or r i (list "" '()))))))
                                          (string-length (nth header i)) rows*)
                                   acc))))))
    (list (car (k8s--join-cells (map k8s--cell header) widths))
          (map (lambda (r) (k8s--join-cells r widths)) rows*))))
;; Optional columns / list items: `lst` when `c`, else '(). A macro so `lst`
;; isn't evaluated (and can't fail) when `c` is false.
(define-syntax k8s--when (syntax-rules () ((_ c lst) (if c lst '()))))
(define (k8s--colored text face) (list text (list (list 0 (utf8-length text) face))))

;; A meter cell, `██████░░░░  60%`, as (text accents).
(define k8s--bar-width 10)
(define (k8s--meter-cells pct)
  (if pct (quotient (+ (* (max 0 (min 100 pct)) k8s--bar-width) 50) 100) 0))
(define (k8s--meter pct label label-w)
  (if (not pct)
      (list "-" '())
      (let* ((n     (k8s--meter-cells pct))
             (fill  (k8s--repeat "█" n))
             (empty (k8s--repeat "░" (- k8s--bar-width n)))
             (num   (k8s--pad-left label label-w))
             (face  (k8s--pack-face pct))
             (a     (utf8-length fill))
             (b     (+ a (utf8-length empty))))
        (list (string-append fill empty num)
              (list (list 0 a face) (list a b "k8s-dim")
                    (list b (+ b (utf8-length num)) face))))))
;; Pod slots: running pods vs the node's allocatable pod limit, e.g. `19/110`.
(define (k8s--pods-meter pods pmax)
  (if (and pods pmax (> pmax 0))
      (k8s--meter (quotient (* 100 pods) pmax) (string-append (k8s--str pods) "/" (k8s--str pmax)) 8)
      (list "-" '())))
;; Usage inside requests: `██▒▒▒▒▒░░░  10/70%` — █ actually used, ▒ requested
;; but idle, ░ unrequested. Colored by the requests (what the scheduler packs on).
(define (k8s--use-req-meter use req)
  (if (not (or use req))
      (list "-" '())
      (let* ((nu   (k8s--meter-cells use))
             (nr   (max nu (k8s--meter-cells req)))
             (face (k8s--pack-face (or req use)))
             (a    (k8s--repeat "█" nu))
             (b    (k8s--repeat "▒" (- nr nu)))
             (c    (k8s--repeat "░" (- k8s--bar-width nr)))
             (lab  (k8s--pad-left (string-append (if use (k8s--str use) "-") "/"
                                                 (if req (k8s--str req) "-") "%") 9))
             (ba   (utf8-length a)) (bb (+ ba (utf8-length b))) (bc (+ bb (utf8-length c))))
        (list (string-append a b c lab)
              (list (list 0 bb face) (list bb bc "k8s-dim") (list bc (+ bc (utf8-length lab)) face))))))
;; A sparkline cell (empty until there are two samples).
;; Top of a sparkline scale: a quarter above the peak (+1 so tiny integer
;; series like 3,3,3 read mid-height rather than as a solid bar).
(define (k8s--headroom vals)
  (if (null? vals) 1 (let ((m (apply max vals))) (+ m (quotient m 4) 1))))
(define (k8s--spark vals lo hi)
  (if (< (length vals) 2)
      (list "" '())
      (k8s--colored (textplot-sparkline vals lo hi) "k8s-accent")))

;; ── emitting ──────────────────────────────────────────────────────────────────
;; Record which resource sits on a rendered line, so d/l/y/s/x/TAB can resolve
;; it: rec is (kind name ns [container expand-key]).
(define (k8s--record! line rec)
  (k8s--st! 'linemap (cons (cons line rec) (k8s--st 'linemap))))
;; Apply a row's relative accents at absolute byte `base`.
(define (k8s--accent-row base accs)
  (for-each (lambda (x) (section-accent (+ base (nth x 0)) (+ base (nth x 1)) (nth x 2)))
            accs))
;; One line: `indent` + row text, whole-line `face`, row accents, optional record.
(define (k8s--emit-row indent row face rec)
  (when rec (k8s--record! (section-point-line) rec))
  (k8s--accent-row (+ (section-point-byte) (utf8-length indent)) (cadr row))
  (section-line (string-append indent (car row)) face))
;; A heading `label` whose `extras` ((text face) …) follow it, each accented.
(define (k8s--open-heading id label face extras)
  (let loop ((es extras) (text label) (accs '()))
    (if (null? es)
        (begin (k8s--accent-row (section-point-byte) accs) (section-open id text face))
        (let* ((t (string-append "  " (car (car es))))
               (b (utf8-length text)))
          (loop (cdr es) (string-append text t)
                (cons (list (+ b 2) (+ b (utf8-length t)) (cadr (car es))) accs))))))
(define (k8s--count-label label n) (string-append label " (" (k8s--str n) ")"))
;; A flat table section: header dim, one row per item (row face rec).
(define (k8s--emit-table-section id label extras header rows)
  (k8s--open-heading id (k8s--count-label label (length rows)) "k8s-section" extras)
  (if (null? rows)
      (section-line "    (none)" "k8s-dim")
      (let ((t (k8s--table header (map car rows))))
        (section-line (string-append "  " (car t)) "k8s-dim")
        (for-each (lambda (ri) (k8s--emit-row "  " (car ri) (nth (cdr ri) 1) (nth (cdr ri) 2)))
                  (k8s--zip (cadr t) rows))))
  (section-close id)
  (section-line "" #f))
(define (k8s--ns-cells o) (k8s--when (k8s--st 'all-ns) (list (k8s--ns-of o))))
(define (k8s--ns-header) (k8s--when (k8s--st 'all-ns) (list "NAMESPACE")))

;; ── model: pods, workloads, jobs ──────────────────────────────────────────────
(define (k8s--items d kind)
  (filter (lambda (i) (equal? (k8s--js i 'kind) kind)) (hash-ref d 'items)))
(define (k8s--short-kind k)
  (cond ((equal? k "Deployment") "deploy") ((equal? k "StatefulSet") "sts")
        ((equal? k "DaemonSet") "ds") ((equal? k "CronJob") "cronjob")
        ((equal? k "Job") "job") (else "")))

;; A Job's family when no CronJob owns it: its name minus a long numeric suffix
;; (`fr-sync-1791403453` → `fr-sync`), so ad-hoc runs still group together.
(define (k8s--job-family name)
  (let ((seg (k8s--last-segment name)))
    (if (and (k8s--digits? seg) (>= (string-length seg) 6)) (k8s--strip-last-segment name) name)))
;; "ns/job" -> owning CronJob name, or #f.
(define (k8s--job-owner-map jobs)
  (map (lambda (j)
         (let ((o (k8s--j j 'metadata 'ownerReferences 0)))
           (cons (string-append (k8s--ns-of j) "/" (k8s--name j))
                 (and o (equal? (k8s--js o 'kind) "CronJob") (k8s--js o 'name)))))
       jobs))
;; The group a pod belongs to: (kind name). A ReplicaSet collapses to its
;; Deployment (minus the pod-template-hash), a Job to its CronJob (or family).
(define (k8s--pod-owner p jobmap)
  (let* ((o (k8s--j p 'metadata 'ownerReferences 0))
         (kind (if o (k8s--js o 'kind) ""))
         (name (if o (k8s--js o 'name) "")))
    (cond ((not o) (list "" "(no controller)"))
          ((equal? kind "ReplicaSet")
           (let ((h (k8s--label p "pod-template-hash")))
             (list "Deployment"
                   (if (and h (ends-with? name (string-append "-" h)))
                       (substring name 0 (- (string-length name) (+ 1 (string-length h))))
                       (k8s--strip-last-segment name)))))
          ((equal? kind "Job")
           (let ((cj (alist-ref jobmap (string-append (k8s--ns-of p) "/" name))))
             (if cj (list "CronJob" cj) (list "Job" (k8s--job-family name)))))
          (else (list kind name)))))

;; kubectl's pod STATUS (simplified): init progress, else the most telling
;; container waiting/terminated reason, else the phase; Terminating overrides.
(define (k8s--init-status p)
  (let ((n (length (k8s--jl p 'spec 'initContainers))))
    (let loop ((l (k8s--jl p 'status 'initContainerStatuses)) (i 0))
      (if (null? l)
          #f
          (let* ((c (car l)) (term (k8s--j c 'state 'terminated)) (wait (k8s--j c 'state 'waiting)))
            (cond ((and term (= 0 (k8s--ji term 'exitCode))) (loop (cdr l) (+ i 1)))
                  (term (string-append "Init:" (or (k8s--j term 'reason) "Error")))
                  ((and wait (k8s--j wait 'reason)
                        (not (equal? (k8s--js wait 'reason) "PodInitializing")))
                   (string-append "Init:" (k8s--js wait 'reason)))
                  (else (string-append "Init:" (k8s--str i) "/" (k8s--str n)))))))))
(define (k8s--container-status cs base)
  (let loop ((l (reverse cs)) (reason base) (running #f))
    (if (null? l)
        (if (and running (equal? reason "Completed")) "Running" reason)
        (let* ((c (car l)) (wait (k8s--j c 'state 'waiting)) (term (k8s--j c 'state 'terminated)))
          (cond ((and wait (k8s--j wait 'reason)) (loop (cdr l) (k8s--js wait 'reason) running))
                ((and term (k8s--j term 'reason)) (loop (cdr l) (k8s--js term 'reason) running))
                (term (loop (cdr l) (if (k8s--j term 'signal)
                                        (string-append "Signal:" (k8s--str (k8s--ji term 'signal)))
                                        (string-append "ExitCode:" (k8s--str (k8s--ji term 'exitCode))))
                            running))
                ((and (k8s--j c 'state 'running) (k8s--j c 'ready)) (loop (cdr l) reason #t))
                (else (loop (cdr l) reason running)))))))
(define (k8s--pod-status p)
  (let* ((base (or (k8s--j p 'status 'reason) (k8s--j p 'status 'phase) "Unknown"))
         (init (k8s--init-status p))
         (s    (or init (k8s--container-status (k8s--jl p 'status 'containerStatuses) base))))
    (if (k8s--j p 'metadata 'deletionTimestamp) "Terminating" s)))
;; "OOMKilled 2h" — the most-restarted container's last termination.
(define (k8s--last-term cs)
  (let ((worst (foldl (lambda (c best) (if (or (not best) (> (k8s--ji c 'restartCount)
                                                            (k8s--ji best 'restartCount)))
                                           c best))
                      #f cs)))
    (if (and worst (> (k8s--ji worst 'restartCount) 0) (k8s--j worst 'lastState 'terminated))
        (let ((t (k8s--j worst 'lastState 'terminated)))
          (string-append (or (k8s--j t 'reason) "Error") " " (k8s--since (k8s--js t 'finishedAt))))
        "")))
(define (k8s--container-state c)
  (cond ((k8s--j c 'state 'running) (if (k8s--j c 'ready) "Running" "Running (not ready)"))
        ((k8s--j c 'state 'waiting) (k8s--js c 'state 'waiting 'reason))
        ((k8s--j c 'state 'terminated) (or (k8s--j c 'state 'terminated 'reason) "Terminated"))
        (else "-")))

;; Everything the sections share, derived once per render from 'data.
(define (k8s--model d)
  (let* ((jobs   (k8s--items d "Job"))
         (jobmap (k8s--job-owner-map jobs))
         (all    (k8s--st 'all-ns))
         (pods
          (map (lambda (p)
                 (let* ((cs  (k8s--jl p 'status 'containerStatuses))
                        (own (k8s--pod-owner p jobmap))
                        (ns  (k8s--ns-of p))
                        (st  (k8s--pod-status p)))
                   (hash 'raw p 'name (k8s--name p) 'ns ns
                         'gkind (car own) 'gname (cadr own)
                         'gid (string-append ns "/" (car own) "/" (cadr own))
                         'node (k8s--js p 'spec 'nodeName)
                         'status st 'face (k8s--phase-face st)
                         'phase (k8s--js p 'status 'phase)
                         'ready (length (filter (lambda (c) (eq? (k8s--j c 'ready) #t)) cs))
                         'total (max (length cs) (length (k8s--jl p 'spec 'containers)))
                         'restarts (k8s--sum (map (lambda (c) (k8s--ji c 'restartCount)) cs))
                         'lastterm (k8s--last-term cs)
                         'containers cs
                         'created (k8s--created p)
                         'key (string-append ns "/" (k8s--name p)))))
               (k8s--items d "Pod")))
         (gids (k8s--uniq (map (lambda (p) (hash-ref p 'gid)) pods)))
         (groups (sort (map (lambda (g) (cons g (filter (lambda (p) (equal? (hash-ref p 'gid) g)) pods)))
                            gids)
                       (lambda (a b) (string<? (hash-ref (cadr a) 'gname) (hash-ref (cadr b) 'gname)))))
         (pools (k8s--node-pools (hash-ref d 'nodes))))
    (hash 'pods pods 'groups groups 'jobs jobs 'pools pools
          'spread (k8s--spread-map groups))))
(define (k8s--group-pods m gid)
  (let ((g (assoc gid (hash-ref m 'groups)))) (if g (cdr g) '())))
;; Running pods of a group → their distinct nodes.
(define (k8s--group-nodes pods)
  (k8s--uniq (map (lambda (p) (hash-ref p 'node))
                  (filter (lambda (p) (equal? (hash-ref p 'phase) "Running")) pods))))
;; gid -> the single node every replica sits on, for Deployments / StatefulSets
;; with 2+ running replicas and no spread at all.
(define (k8s--spread-map groups)
  (foldl (lambda (g acc)
           (let* ((pods (cdr g)) (kind (hash-ref (car pods) 'gkind))
                  (running (filter (lambda (p) (equal? (hash-ref p 'phase) "Running")) pods))
                  (nodes (k8s--group-nodes pods)))
             (if (and (member kind (list "Deployment" "StatefulSet"))
                      (>= (length running) 2) (= (length nodes) 1))
                 (cons (cons (car g) (car nodes)) acc)
                 acc)))
         '() groups))

;; ── nodes ─────────────────────────────────────────────────────────────────────
;; Configured node-pool label (option store, "" = auto-detect). See k8s--shell
;; for why config lives in the option store rather than a Scheme var.
(define (k8s--node-group-label)
  (let ((v (get-option "k8s-node-group-label"))) (if (string? v) v "")))
;; The label(s) to try for a node's pool — the configured one, else the known
;; cloud node-pool labels in priority order.
(define (k8s--node-group-candidates)
  (let ((lbl (k8s--node-group-label)))
    (if (equal? lbl "")
        (list "eks.amazonaws.com/nodegroup" "cloud.google.com/gke-nodepool"
              "karpenter.sh/nodepool" "kubernetes.azure.com/agentpool" "agentpool")
        (list lbl))))
;; node-name -> pool (or #f).
(define (k8s--node-pools nodes)
  (let ((cands (k8s--node-group-candidates)))
    (map (lambda (n)
           (cons (k8s--name n)
                 (foldl (lambda (c found) (or found (let ((v (k8s--label n c))) (and (string? v) v))))
                        #f cands)))
         nodes)))
;; Short node name for the pod table: "ondemand/ict8" (pool + last segment).
(define (k8s--short-node m name)
  (let ((pool (alist-ref (hash-ref m 'pools) name)))
    (if (and pool (not (equal? name ""))) (string-append pool "/" (k8s--last-segment name)) name)))
(define (k8s--node-status n)
  (let* ((ready (filter (lambda (c) (equal? (k8s--js c 'type) "Ready")) (k8s--jl n 'status 'conditions)))
         (s (if (and (pair? ready) (equal? (k8s--js (car ready) 'status) "True")) "Ready" "NotReady")))
    (if (k8s--j n 'spec 'unschedulable) (string-append s ",SchedulingDisabled") s)))
(define (k8s--node-roles n)
  (let* ((labels (k8s--j n 'metadata 'labels))
         (keys (if (hash? labels) (map symbol->string (hash-keys->list labels)) '()))
         (roles (map (lambda (k) (substring k 24 (string-length k)))
                     (filter (lambda (k) (starts-with? k "node-role.kubernetes.io/")) keys))))
    (if (null? roles) "" (string-join (sort roles string<?) ","))))
(define (k8s--node-ip n)
  (let ((a (filter (lambda (x) (equal? (k8s--js x 'type) "InternalIP")) (k8s--jl n 'status 'addresses))))
    (if (null? a) "" (k8s--js (car a) 'address))))
;; Node-info fields: identical on every node → shown once in the heading;
;; otherwise a column (that's when you care, e.g. mid-upgrade).
(define k8s--node-info
  (list (list "VERSION" 'kubeletVersion) (list "OS-IMAGE" 'osImage)
        (list "KERNEL" 'kernelVersion) (list "RUNTIME" 'containerRuntimeVersion)))

(define (k8s--emit-nodes d m)
  (let* ((nodes   (k8s--by-name (hash-ref d 'nodes)))
         (info    (lambda (n field) (k8s--js n 'status 'nodeInfo field)))
         (uniform (filter (lambda (f) (= 1 (length (k8s--uniq (map (lambda (n) (info n (cadr f))) nodes)))))
                          k8s--node-info))
         (varying (filter (lambda (f) (not (member f uniform))) k8s--node-info))
         (roles?  (foldl (lambda (n a) (or a (not (equal? (k8s--node-roles n) "")))) #f nodes))
         (pack    (hash-ref d 'pack))
         (top     (hash-ref d 'tnodes))
         (metrics (not (null? top)))
         (trend?  (and metrics (pair? nodes)
                       (>= (length (k8s--hist (string-append "cpu:" (k8s--name (car nodes))))) 2)))
         (header  (append (list "NAME" "STATUS") (k8s--when roles? (list "ROLES"))
                          (list "AGE" "INTERNAL-IP") (map car varying)
                          (list "PODS" "CPU use/req" "MEM use/req")
                          (k8s--when trend? (list "CPU TREND" "MEM TREND"))))
         (rows
          (map (lambda (n)
                 (let* ((name (k8s--name n)) (st (k8s--node-status n))
                        (pk (alist-ref pack name)) (tp (alist-ref top name)))
                   (list (append (list name st) (k8s--when roles? (list (k8s--node-roles n)))
                                 (list (k8s--age n) (k8s--node-ip n))
                                 (map (lambda (f) (info n (cadr f))) varying)
                                 (list (k8s--pods-meter (and pk (nth pk 2)) (and pk (nth pk 3)))
                                       (k8s--use-req-meter (and tp (car tp)) (and pk (nth pk 0)))
                                       (k8s--use-req-meter (and tp (cadr tp)) (and pk (nth pk 1))))
                                 (k8s--when trend?
                                            (list (k8s--spark (k8s--hist (string-append "cpu:" name)) 0 100)
                                                  (k8s--spark (k8s--hist (string-append "mem:" name)) 0 100))))
                         (cond ((equal? st "Ready") "k8s-ok")
                               ((starts-with? st "Ready") "k8s-warn")
                               (else "k8s-err"))
                         (list "node" name ""))))
               nodes))
         (extras (map (lambda (f) (list (if (null? nodes) "" (info (car nodes) (cadr f))) "k8s-dim"))
                      (if (null? nodes) '() uniform)))
         (pools  (k8s--uniq (map (lambda (n) (or (alist-ref (hash-ref m 'pools) (k8s--name n)) "(no pool)"))
                                 nodes)))
         (note   (string-append "    use/req = actual usage / scheduled requests, % of allocatable"
                                " (node-wide: every namespace)"
                                (if metrics "" " · no metrics-server, usage unavailable"))))
    (if (< (length pools) 2)
        (begin
          (k8s--open-heading 'k8s-nodes (k8s--count-label "Nodes" (length nodes)) "k8s-section" extras)
          (if (null? rows)
              (section-line "    (none)" "k8s-dim")
              (let ((t (k8s--table header (map car rows))))
                (section-line (string-append "  " (car t)) "k8s-dim")
                (for-each (lambda (ri) (k8s--emit-row "  " (car ri) (nth (cdr ri) 1) (nth (cdr ri) 2)))
                          (k8s--zip (cadr t) rows))
                (section-line note "k8s-dim"))))
        ;; Grouped by pool: one table (shared column widths), a fold per pool.
        (let ((t (k8s--table header (map car rows))))
          (k8s--open-heading 'k8s-nodes (k8s--count-label "Nodes" (length nodes)) "k8s-section" extras)
          (section-line (string-append "    " (car t)) "k8s-dim")
          (for-each
           (lambda (pool)
             (let* ((pairs (filter (lambda (pr) (equal? (or (alist-ref (hash-ref m 'pools) (nth (cadr pr) 1))
                                                           "(no pool)")
                                                       pool))
                                   (map (lambda (ri) (list (car ri) (nth (cdr ri) 2) (nth (cdr ri) 1)))
                                        (k8s--zip (cadr t) rows))))
                    (id (string-append "k8s-nodes/" pool)))
               (section-open id (string-append "  " (k8s--count-label pool (length pairs)))
                             (k8s--worst-face (map (lambda (pr) (nth pr 2)) pairs)))
               (for-each (lambda (pr) (k8s--emit-row "    " (car pr) (nth pr 2) (cadr pr))) pairs)
               (section-close id)))
           pools)
          (section-line note "k8s-dim")))
    (section-close 'k8s-nodes)
    (section-line "" #f)))

;; ── workloads (deployments, statefulsets, daemonsets) ─────────────────────────
(define (k8s--workload-counts w)
  (let ((kind (k8s--js w 'kind)))
    (if (equal? kind "DaemonSet")
        (list (k8s--ji w 'status 'desiredNumberScheduled) (k8s--ji w 'status 'numberReady)
              (k8s--ji w 'status 'updatedNumberScheduled) (k8s--ji w 'status 'numberAvailable))
        (list (if (k8s--j w 'spec 'replicas) (k8s--ji w 'spec 'replicas) 1)
              (k8s--ji w 'status 'readyReplicas) (k8s--ji w 'status 'updatedReplicas)
              (k8s--ji w 'status 'availableReplicas)))))
(define (k8s--kind-resource kind)
  (cond ((equal? kind "Deployment") "deployment") ((equal? kind "StatefulSet") "statefulset")
        ((equal? kind "DaemonSet") "daemonset") (else (string-downcase kind))))
(define (k8s--emit-workloads d m)
  (let* ((ws (k8s--by-name (append (k8s--items d "Deployment") (k8s--items d "StatefulSet")
                                   (k8s--items d "DaemonSet"))))
         (rows
          (map (lambda (w)
                 (let* ((kind (k8s--js w 'kind))
                        (gid (string-append (k8s--ns-of w) "/" kind "/" (k8s--name w)))
                        (c (k8s--workload-counts w))
                        (nodes (k8s--group-nodes (k8s--group-pods m gid)))
                        (lone (assoc gid (hash-ref m 'spread))))
                   (list (append (k8s--ns-cells w)
                                 (list (k8s--name w) (k8s--short-kind kind)
                                       (string-append (k8s--str (nth c 1)) "/" (k8s--str (nth c 0)))
                                       (k8s--str (nth c 2)) (k8s--str (nth c 3))
                                       (cond (lone (k8s--colored "1 ▲ no spread" "k8s-warn"))
                                             ((null? nodes) "-")
                                             (else (k8s--str (length nodes))))
                                       (k8s--age w)))
                         (cond ((= (nth c 0) 0) "k8s-dim")
                               ((= (nth c 1) (nth c 0)) "k8s-ok")
                               (else "k8s-warn"))
                         (list (k8s--kind-resource kind) (k8s--name w) (k8s--ns-of w)))))
               ws)))
    (k8s--emit-table-section 'k8s-workloads "Workloads" '()
                             (append (k8s--ns-header)
                                     (list "NAME" "KIND" "READY" "UP-TO-DATE" "AVAILABLE" "NODES" "AGE"))
                             rows)))

;; ── autoscalers ───────────────────────────────────────────────────────────────
;; Each spec.metrics entry as (label current% target%) — current #f when the
;; HPA can't read metrics yet (kubectl's <unknown>).
(define (k8s--hpa-metrics h)
  (map (lambda (spec)
         (let* ((type (k8s--js spec 'type))
                (key  (cond ((equal? type "Resource") 'resource)
                            ((equal? type "ContainerResource") 'containerResource)
                            ((equal? type "Pods") 'pods) ((equal? type "Object") 'object)
                            (else 'external)))
                (name (or (k8s--j spec key 'name) (k8s--j spec key 'metric 'name) type))
                (cur  (filter (lambda (c) (and (equal? (k8s--js c 'type) type)
                                               (equal? (or (k8s--j c key 'name) (k8s--j c key 'metric 'name) type)
                                                       name)))
                              (k8s--jl h 'status 'currentMetrics)))
                (tgt  (k8s--j spec key 'target))
                (pct? (k8s--j tgt 'averageUtilization)))
           (list name
                 (and (pair? cur)
                      (if pct? (k8s--ji (car cur) key 'current 'averageUtilization)
                          (or (k8s--j (car cur) key 'current 'averageValue)
                              (k8s--j (car cur) key 'current 'value))))
                 (if pct? (k8s--ji tgt 'averageUtilization)
                     (or (k8s--j tgt 'averageValue) (k8s--j tgt 'value) "?"))
                 pct?)))
       (k8s--jl h 'spec 'metrics)))
(define (k8s--hpa-target-text ms)
  (if (null? ms)
      "-"
      (string-join
       (map (lambda (x)
              (let ((fmt (lambda (v) (cond ((not v) "<unknown>")
                                           ((number? v) (string-append (k8s--str v) (if (nth x 3) "%" "")))
                                           (else v)))))
                (string-append (car x) ": " (fmt (nth x 1)) "/" (fmt (nth x 2)))))
            ms)
       ", ")))
;; (note face) — at max (can't scale further), or pinned at min far under
;; target (requests set much higher than the pods use).
(define (k8s--hpa-note h ms)
  (let ((rep (k8s--ji h 'status 'currentReplicas)) (mx (k8s--ji h 'spec 'maxReplicas))
        (mn (if (k8s--j h 'spec 'minReplicas) (k8s--ji h 'spec 'minReplicas) 1))
        (pcts (filter (lambda (x) (and (nth x 3) (number? (nth x 1)))) ms)))
    (cond ((k8s--any (lambda (x) (not (nth x 1))) ms) (list "metrics unavailable" "k8s-err"))
          ((and (> mx 0) (>= rep mx)) (list "at max" "k8s-warn"))
          ((and (= rep mn) (pair? pcts)
                (k8s--all (lambda (x) (< (* 4 (nth x 1)) (nth x 2))) pcts))
           (list "idle at min · requests high?" "k8s-dim"))
          (else (list "" "k8s-ok")))))
(define (k8s--emit-hpas d)
  (let ((rows
         (map (lambda (h)
                (let* ((ms (k8s--hpa-metrics h)) (note (k8s--hpa-note h ms)))
                  (list (append (k8s--ns-cells h)
                                (list (k8s--name h)
                                      (string-append (k8s--js h 'spec 'scaleTargetRef 'kind) "/"
                                                     (k8s--js h 'spec 'scaleTargetRef 'name))
                                      (k8s--hpa-target-text ms)
                                      (k8s--str (if (k8s--j h 'spec 'minReplicas) (k8s--ji h 'spec 'minReplicas) 1))
                                      (k8s--str (k8s--ji h 'spec 'maxReplicas))
                                      (k8s--str (k8s--ji h 'status 'currentReplicas))
                                      (k8s--colored (car note) (cadr note))
                                      (k8s--age h)))
                        (if (equal? (cadr note) "k8s-dim") "k8s-ok" (cadr note))
                        (list "hpa" (k8s--name h) (k8s--ns-of h)))))
              (k8s--by-name (k8s--items d "HorizontalPodAutoscaler")))))
    (k8s--emit-table-section 'k8s-hpa "Autoscalers" '()
                             (append (k8s--ns-header)
                                     (list "NAME" "REFERENCE" "TARGETS" "MIN" "MAX" "REPLICAS" "NOTE" "AGE"))
                             rows)))

;; ── jobs (cronjobs + job families) ────────────────────────────────────────────
;; A Job's result: "running" / "failed" / "ok".
(define (k8s--job-result j)
  (let ((conds (k8s--jl j 'status 'conditions))
        (true? (lambda (type) (lambda (c) (and (equal? (k8s--js c 'type) type)
                                               (equal? (k8s--js c 'status) "True"))))))
    (cond ((pair? (filter (true? "Failed") conds)) "failed")
          ((or (pair? (filter (true? "Complete") conds)) (> (k8s--ji j 'status 'succeeded) 0)) "ok")
          ((> (k8s--ji j 'status 'active) 0) "running")
          (else "pending"))))
(define (k8s--result-face r)
  (cond ((equal? r "ok") "k8s-ok") ((equal? r "failed") "k8s-err") (else "k8s-warn")))
;; Seconds a Job ran (so far, while running), or #f.
(define (k8s--job-secs j)
  (let ((s (k8s--epoch (k8s--js j 'status 'startTime)))
        (e (k8s--epoch (k8s--js j 'status 'completionTime))))
    (cond ((and s e) (- e s)) (s (- (k8s--st 'now) s)) (else #f))))
;; Durations of the retained runs as a sparkline, each glyph colored by result.
(define (k8s--runs-cell jobs)
  (let* ((done (filter k8s--job-secs jobs))
         (secs (map k8s--job-secs done)))
    (if (null? secs)
        (list "" '())
        (let* ((s (textplot-sparkline secs 0 (k8s--headroom secs)))
               (glyphs (map (lambda (c) (list->string (list c))) (string->list s))))
          (let loop ((gs glyphs) (js done) (off 0) (accs '()))
            (if (null? gs)
                (list s (reverse accs))
                (let ((w (utf8-length (car gs))))
                  (loop (cdr gs) (cdr js) (+ off w)
                        (cons (list off (+ off w) (k8s--result-face (k8s--job-result (car js)))) accs)))))))))
(define (k8s--emit-jobs d m)
  (let* ((jobs (hash-ref m 'jobs))
         (jobmap (k8s--job-owner-map jobs))
         (runs-of (lambda (ns pred)
                    (sort (filter (lambda (j) (and (equal? (k8s--ns-of j) ns) (pred j))) jobs)
                          (lambda (a b) (< (k8s--created a) (k8s--created b))))))
         (owner (lambda (j) (alist-ref jobmap (string-append (k8s--ns-of j) "/" (k8s--name j)))))
         (row
          (lambda (o name schedule runs kind rec-name)
            (let* ((newest (if (null? runs) #f (last runs)))
                   (res (if newest (k8s--job-result newest) "-"))
                   (secs (and newest (k8s--job-secs newest))))
              (list (append (k8s--ns-cells o)
                            (list name schedule
                                  (if newest (string-append (k8s--since (or (k8s--j newest 'status 'startTime)
                                                                            (k8s--js newest 'metadata 'creationTimestamp)))
                                                            " ago")
                                      (let ((t (k8s--j o 'status 'lastScheduleTime)))
                                        (if t (string-append (k8s--since t) " ago") "never")))
                                  (if newest (k8s--colored res (k8s--result-face res)) "-")
                                  (if secs (k8s--human secs) "-")
                                  (k8s--runs-cell runs)
                                  (k8s--age o)))
                    (if newest (k8s--result-face res) "k8s-dim")
                    (list kind rec-name (k8s--ns-of o))))))
         (cron-rows
          (map (lambda (cj)
                 (row cj (k8s--name cj)
                      (string-append (k8s--js cj 'spec 'schedule)
                                     (if (k8s--j cj 'spec 'suspend) " (suspended)" ""))
                      (runs-of (k8s--ns-of cj) (lambda (j) (equal? (owner j) (k8s--name cj))))
                      "cronjob" (k8s--name cj)))
               (k8s--by-name (k8s--items d "CronJob"))))
         (loose (filter (lambda (j) (not (owner j))) jobs))
         (families (k8s--uniq (map (lambda (j) (cons (k8s--ns-of j) (k8s--job-family (k8s--name j)))) loose)))
         (job-rows
          (map (lambda (f)
                 (let ((runs (runs-of (car f) (lambda (j) (and (not (owner j))
                                                               (equal? (k8s--job-family (k8s--name j)) (cdr f)))))))
                   (row (last runs) (cdr f) "-" runs "job" (k8s--name (last runs)))))
               families)))
    (k8s--emit-table-section 'k8s-jobs "Jobs" '()
                             (append (k8s--ns-header)
                                     (list "NAME" "SCHEDULE" "LAST RUN" "RESULT" "DURATION" "RUNS" "AGE"))
                             (append cron-rows job-rows))))

;; ── pods ──────────────────────────────────────────────────────────────────────
;; Grouped by owning workload, one fold per group. A multi-container pod gets a
;; ▸ and expands (TAB) into its containers; a job group shows its live pods plus
;; the latest run, the earlier runs behind a TAB-expandable "… N earlier runs".
(define (k8s--expanded? key) (member key (k8s--st 'expanded)))
(define (k8s--toggle-expanded! key)
  (k8s--st! 'expanded (if (k8s--expanded? key)
                          (filter (lambda (k) (not (equal? k key))) (k8s--st 'expanded))
                          (cons key (k8s--st 'expanded)))))
(define (k8s--pod-cpu-cell p tp)
  (let* ((h (k8s--hist (string-append "pod:" (hash-ref p 'key))))
         (now (and tp (car tp))))
    (if (not now)
        "-"
        (let ((sp (k8s--spark (k8s--last-n h 8) 0 (k8s--headroom (k8s--last-n h 8))))
              (n (string-append (k8s--str now) "m")))
          (if (equal? (car sp) "")
              n
              (list (string-append (car sp) " " n) (cadr sp)))))))
(define (k8s--emit-pods d m)
  (let* ((pods (hash-ref m 'pods))
         (top (hash-ref d 'tpods))
         (metrics (not (null? top)))
         (lastterm? (k8s--any (lambda (p) (not (equal? (hash-ref p 'lastterm) ""))) pods))
         (header (append (k8s--ns-header) (list "NAME" "READY" "STATUS" "RESTARTS")
                         (k8s--when lastterm? (list "LAST TERMINATION"))
                         (list "AGE") (k8s--when metrics (list "CPU" "MEM")) (list "IP" "NODE")))
         (cells
          (lambda (p)
            (let ((tp (alist-ref top (hash-ref p 'key))))
              (append (k8s--when (k8s--st 'all-ns) (list (hash-ref p 'ns)))
                      (list (hash-ref p 'name)
                            (string-append (k8s--str (hash-ref p 'ready)) "/" (k8s--str (hash-ref p 'total)))
                            (hash-ref p 'status)
                            (k8s--str (hash-ref p 'restarts)))
                      (k8s--when lastterm?
                                 (list (if (equal? (hash-ref p 'lastterm) "") ""
                                           (k8s--colored (hash-ref p 'lastterm) "k8s-warn"))))
                      (list (k8s--human (- (k8s--st 'now) (hash-ref p 'created))))
                      (k8s--when metrics (list (k8s--pod-cpu-cell p tp) (if tp (cadr tp) "-")))
                      (list (k8s--js (hash-ref p 'raw) 'status 'podIP)
                            (k8s--short-node m (hash-ref p 'node)))))))
         ;; One shared table so every group's columns line up.
         (t (k8s--table header (map cells pods)))
         (rowmap (map (lambda (pr) (cons (hash-ref (car pr) 'key) (cdr pr))) (k8s--zip pods (cadr t)))))
    (k8s--open-heading 'k8s-pods (k8s--count-label "Pods" (length pods)) "k8s-section" '())
    (if (null? pods)
        (section-line "    (none)" "k8s-dim")
        (begin
          (section-line (string-append "    " (car t)) "k8s-dim")
          (for-each (lambda (g) (k8s--emit-pod-group m (car g) (cdr g) rowmap)) (hash-ref m 'groups))))
    (section-close 'k8s-pods)
    (section-line "" #f)))
(define (k8s--emit-pod-group m gid pods rowmap)
  (let* ((p0 (car pods))
         (kind (hash-ref p0 'gkind))
         (name (hash-ref p0 'gname))
         (id (string-append "k8s-pods/" (if (k8s--st 'all-ns) (string-append (hash-ref p0 'ns) "/") "") name))
         (jobby (member kind (list "CronJob" "Job")))
         (ordered (if jobby
                      (sort pods (lambda (a b) (> (hash-ref a 'created) (hash-ref b 'created))))
                      pods))
         (live (lambda (p) (not (member (hash-ref p 'phase) (list "Succeeded" "Failed")))))
         (grp-key (string-append "grp:" gid))
         (shown (if (or (not jobby) (k8s--expanded? grp-key))
                    ordered
                    (filter (lambda (p) (or (live p) (eq? p (car ordered)))) ordered)))
         (hidden (- (length ordered) (length shown)))
         (lone (alist-ref (hash-ref m 'spread) gid)))
    (k8s--open-heading id (string-append "  " (k8s--count-label name (length pods)))
                       (k8s--worst-face (map (lambda (p) (hash-ref p 'face)) pods))
                       (append (k8s--when (not (equal? kind "")) (list (list (k8s--short-kind kind) "k8s-dim")))
                               (k8s--when lone (list (list (string-append "▲ all on one node ("
                                                                          (k8s--short-node m lone) ")")
                                                           "k8s-warn")))))
    (for-each
     (lambda (p)
       (let* ((key (hash-ref p 'key))
              (multi (> (length (hash-ref p 'containers)) 1))
              (pkey (string-append "pod:" key))
              (open (and multi (k8s--expanded? pkey))))
         (k8s--emit-row (cond (open "  ▾ ") (multi "  ▸ ") (else "    "))
                        (cdr (assoc key rowmap)) (hash-ref p 'face)
                        (list "pod" (hash-ref p 'name) (hash-ref p 'ns) #f (and multi pkey)))
         (when open (k8s--emit-containers p pkey))))
     shown)
    (cond ((> hidden 0)
           (k8s--emit-row "    " (list (string-append "… " (k8s--str hidden) " earlier run"
                                                      (if (= hidden 1) "" "s") " — TAB to show")
                                        '())
                          "k8s-dim" (list "more" name (hash-ref p0 'ns) #f grp-key)))
          ((and jobby (k8s--expanded? grp-key) (> (length ordered) 1))
           (k8s--emit-row "    " (list "… hide earlier runs — TAB" '())
                          "k8s-dim" (list "more" name (hash-ref p0 'ns) #f grp-key))))
    (section-close id)))
(define (k8s--emit-containers p pkey)
  (let ((t (k8s--table (list "CONTAINER" "READY" "STATE" "RESTARTS" "IMAGE")
                       (map (lambda (c)
                              (list (k8s--js c 'name) (if (eq? (k8s--j c 'ready) #t) "yes" "no")
                                    (k8s--container-state c) (k8s--str (k8s--ji c 'restartCount))
                                    (k8s--js c 'image)))
                            (hash-ref p 'containers)))))
    (section-line (string-append "        " (car t)) "k8s-dim")
    (for-each (lambda (rc)
                (let ((c (cdr rc)))
                  (k8s--emit-row "        " (car rc) (k8s--phase-face (k8s--container-state c))
                                 (list "pod" (hash-ref p 'name) (hash-ref p 'ns) (k8s--js c 'name) pkey))))
              (k8s--zip (cadr t) (hash-ref p 'containers)))))

;; ── services / ingresses / volumes ────────────────────────────────────────────
(define (k8s--svc-ports s)
  (string-join
   (map (lambda (p)
          (string-append (k8s--str (k8s--ji p 'port))
                         (if (k8s--j p 'nodePort) (string-append ":" (k8s--str (k8s--ji p 'nodePort))) "")
                         "/" (let ((pr (k8s--js p 'protocol))) (if (equal? pr "") "TCP" pr))))
        (k8s--jl s 'spec 'ports))
   ","))
(define (k8s--labels-match? selector labels)
  (and (hash? selector) (hash? labels)
       (k8s--all (lambda (kv) (equal? (hash-try-get labels (car kv)) (cdr kv))) (hash->list selector))))
(define (k8s--emit-services d m)
  (let* ((slices (k8s--items d "EndpointSlice"))
         (pods (hash-ref m 'pods))
         (ext? (k8s--any (lambda (s) (pair? (k8s--jl s 'status 'loadBalancer 'ingress))) (k8s--items d "Service")))
         (rows
          (map (lambda (s)
                 (let* ((name (k8s--name s)) (ns (k8s--ns-of s))
                        (sel (k8s--j s 'spec 'selector))
                        (mine (filter (lambda (sl) (and (equal? (k8s--ns-of sl) ns)
                                                        (equal? (k8s--label sl "kubernetes.io/service-name") name)))
                                      slices))
                        (eps (apply append (map (lambda (sl) (k8s--jl sl 'endpoints)) mine)))
                        (ready (length (filter (lambda (e) (not (eq? (k8s--j e 'conditions 'ready) #f))) eps)))
                        (type (k8s--js s 'spec 'type))
                        (backends (k8s--uniq (map (lambda (p) (hash-ref p 'gname))
                                                  (filter (lambda (p) (and (equal? (hash-ref p 'ns) ns)
                                                                           (k8s--labels-match? sel (k8s--j (hash-ref p 'raw) 'metadata 'labels))))
                                                          pods))))
                        (backend (cond ((equal? type "ExternalName") (string-append "→ " (k8s--js s 'spec 'externalName)))
                                       ((not (hash? sel))
                                        (if (null? eps) "(no selector)"
                                            (string-append "manual → " (k8s--js (car eps) 'addresses 0))))
                                       ((null? backends) "(no matching pods)")
                                       (else (k8s--join-some backends 3))))
                        (face (cond ((equal? type "ExternalName") "k8s-dim")
                                    ((and (hash? sel) (= ready 0)) "k8s-warn")
                                    ((< ready (length eps)) "k8s-warn")
                                    (else "k8s-ok"))))
                   (list (append (k8s--ns-cells s)
                                 (list name type (k8s--js s 'spec 'clusterIP))
                                 (k8s--when ext? (list (string-join (map (lambda (i) (or (k8s--j i 'ip) (k8s--js i 'hostname)))
                                                                         (k8s--jl s 'status 'loadBalancer 'ingress))
                                                                    ",")))
                                 (list (k8s--svc-ports s)
                                       (if (equal? type "ExternalName") "-"
                                           (k8s--colored (string-append (k8s--str ready) "/" (k8s--str (length eps))) face))
                                       backend (k8s--age s)))
                         face
                         (list "service" name ns))))
               (k8s--by-name (k8s--items d "Service")))))
    (k8s--emit-table-section 'k8s-svcs "Services" '()
                             (append (k8s--ns-header) (list "NAME" "TYPE" "CLUSTER-IP")
                                     (k8s--when ext? (list "EXTERNAL-IP"))
                                     (list "PORT(S)" "ENDPOINTS" "BACKEND" "AGE"))
                             rows)))
(define (k8s--emit-ingresses d)
  (let ((ings (k8s--by-name (k8s--items d "Ingress"))))
    (when (pair? ings)
      (k8s--emit-table-section
       'k8s-ingresses "Ingresses" '()
       (append (k8s--ns-header) (list "NAME" "CLASS" "HOSTS" "ADDRESS" "BACKENDS" "AGE"))
       (map (lambda (i)
              (let* ((rules (k8s--jl i 'spec 'rules))
                     (svc (lambda (b) (if (k8s--j b 'service 'name)
                                          (string-append (k8s--js b 'service 'name) ":"
                                                         (if (k8s--j b 'service 'port 'number)
                                                             (k8s--str (k8s--ji b 'service 'port 'number))
                                                             (k8s--js b 'service 'port 'name)))
                                          "?")))
                     (backends (k8s--uniq
                                (append (if (k8s--j i 'spec 'defaultBackend) (list (svc (k8s--j i 'spec 'defaultBackend))) '())
                                        (apply append (map (lambda (r) (map (lambda (p) (svc (k8s--j p 'backend)))
                                                                            (k8s--jl r 'http 'paths)))
                                                           rules)))))
                     (addr (map (lambda (x) (or (k8s--j x 'ip) (k8s--js x 'hostname)))
                                (k8s--jl i 'status 'loadBalancer 'ingress))))
                (list (append (k8s--ns-cells i)
                              (list (k8s--name i)
                                    (let ((c (k8s--js i 'spec 'ingressClassName))) (if (equal? c "") "-" c))
                                    (let ((hosts (filter (lambda (h) (not (equal? h "")))
                                                         (map (lambda (r) (k8s--js r 'host)) rules))))
                                      (if (null? hosts) "*" (k8s--join-some hosts 2)))
                                    (if (null? addr) "-" (string-join addr ","))
                                    (k8s--join-some backends 3)
                                    (k8s--age i)))
                      (if (null? addr) "k8s-warn" "k8s-ok")
                      (list "ingress" (k8s--name i) (k8s--ns-of i)))))
            ings)))))
(define (k8s--access-modes v)
  (string-join (map (lambda (a) (cond ((equal? a "ReadWriteOnce") "RWO") ((equal? a "ReadOnlyMany") "ROX")
                                      ((equal? a "ReadWriteMany") "RWX") ((equal? a "ReadWriteOncePod") "RWOP")
                                      (else a)))
                    (k8s--jl v 'status 'accessModes))
               ","))
(define (k8s--emit-volumes d m)
  (let ((pvcs (k8s--by-name (k8s--items d "PersistentVolumeClaim")))
        (pods (hash-ref m 'pods)))
    (when (pair? pvcs)
      (k8s--emit-table-section
       'k8s-pvcs "Volumes" '()
       (append (k8s--ns-header) (list "NAME" "STATUS" "CAPACITY" "ACCESS" "CLASS" "USED BY" "AGE"))
       (map (lambda (v)
              (let* ((phase (k8s--js v 'status 'phase))
                     (users (map (lambda (p) (hash-ref p 'name))
                                 (filter (lambda (p)
                                           (and (equal? (hash-ref p 'ns) (k8s--ns-of v))
                                                (k8s--any (lambda (vol) (equal? (k8s--js vol 'persistentVolumeClaim 'claimName)
                                                                             (k8s--name v)))
                                                       (k8s--jl (hash-ref p 'raw) 'spec 'volumes))))
                                         pods))))
                (list (append (k8s--ns-cells v)
                              (list (k8s--name v) phase
                                    (let ((c (k8s--js v 'status 'capacity 'storage))) (if (equal? c "") "-" c))
                                    (k8s--access-modes v) (k8s--js v 'spec 'storageClassName)
                                    (if (null? users) (k8s--colored "(unused)" "k8s-dim") (k8s--join-some users 2))
                                    (k8s--age v)))
                      (cond ((equal? phase "Bound") "k8s-ok") ((equal? phase "Lost") "k8s-err") (else "k8s-warn"))
                      (list "pvc" (k8s--name v) (k8s--ns-of v)))))
            pvcs)))))

;; ── warnings: derived checks + Warning events ─────────────────────────────────
;; Things worth a look that kubectl won't tell you in one place. Each check is
;; (text face rec-or-#f).
(define (k8s--checks d m)
  (let* ((pack (hash-ref d 'pack))
         (nodes
          (apply append
                 (map (lambda (n)
                        (let* ((name (k8s--name n)) (pk (alist-ref pack name))
                               (bad (filter (lambda (c) (and (member (k8s--js c 'type)
                                                                     (list "MemoryPressure" "DiskPressure" "PIDPressure"))
                                                             (equal? (k8s--js c 'status) "True")))
                                            (k8s--jl n 'status 'conditions)))
                               (st (k8s--node-status n)))
                          (append
                           (k8s--when (not (starts-with? st "Ready"))
                                      (list (list (string-append "✗ node " name " is " st) "k8s-err" (list "node" name ""))))
                           (map (lambda (c) (list (string-append "▲ node " name ": " (k8s--js c 'type)) "k8s-warn"
                                                  (list "node" name "")))
                                bad)
                           (k8s--when (and pk (nth pk 0) (>= (nth pk 0) 90))
                                      (list (list (string-append "▲ node " name ": CPU requests at " (k8s--str (nth pk 0))
                                                                 "% of allocatable — new pods may not fit")
                                                  "k8s-warn" (list "node" name ""))))
                           (k8s--when (and pk (nth pk 1) (>= (nth pk 1) 90))
                                      (list (list (string-append "▲ node " name ": memory requests at " (k8s--str (nth pk 1))
                                                                 "% of allocatable — new pods may not fit")
                                                  "k8s-warn" (list "node" name "")))))))
                      (hash-ref d 'nodes))))
         (spread
          (map (lambda (s)
                 (let* ((pods (k8s--group-pods m (car s))) (p0 (car pods)))
                   (list (string-append "▲ " (k8s--short-kind (hash-ref p0 'gkind)) "/" (hash-ref p0 'gname) ": "
                                        (k8s--str (length (filter (lambda (p) (equal? (hash-ref p 'phase) "Running")) pods)))
                                        " replicas all on " (cdr s)
                                        " — one node failure takes them all (add topologySpreadConstraints)")
                         "k8s-warn"
                         (list (k8s--kind-resource (hash-ref p0 'gkind)) (hash-ref p0 'gname) (hash-ref p0 'ns)))))
               (hash-ref m 'spread)))
         (hpas
          (apply append
                 (map (lambda (h)
                        (let ((note (k8s--hpa-note h (k8s--hpa-metrics h))))
                          (k8s--when (member (car note) (list "at max" "metrics unavailable"))
                                     (list (list (string-append "▲ hpa/" (k8s--name h) ": " (car note) " ("
                                                                (k8s--hpa-target-text (k8s--hpa-metrics h)) ")")
                                                 (cadr note) (list "hpa" (k8s--name h) (k8s--ns-of h)))))))
                      (k8s--items d "HorizontalPodAutoscaler"))))
         (pods
          (apply append
                 (map (lambda (p)
                        (let ((rec (list "pod" (hash-ref p 'name) (hash-ref p 'ns))))
                          (cond ((equal? (hash-ref p 'face) "k8s-err")
                                 (list (list (string-append "✗ pod/" (hash-ref p 'name) ": " (hash-ref p 'status)) "k8s-err" rec)))
                                ((and (> (hash-ref p 'restarts) 0) (not (equal? (hash-ref p 'lastterm) "")))
                                 (list (list (string-append "▲ pod/" (hash-ref p 'name) ": " (k8s--str (hash-ref p 'restarts))
                                                            " restarts, last " (hash-ref p 'lastterm) " ago")
                                             "k8s-warn" rec)))
                                (else '()))))
                      (hash-ref m 'pods))))
         (jobs
          (apply append
                 (map (lambda (j)
                        (k8s--when (equal? (k8s--job-result j) "failed")
                                   (list (list (string-append "✗ job/" (k8s--name j) " failed") "k8s-err"
                                               (list "job" (k8s--name j) (k8s--ns-of j))))))
                      (hash-ref m 'jobs))))
         (pvcs
          (map (lambda (v) (list (string-append "▲ pvc/" (k8s--name v) " is " (k8s--js v 'status 'phase)) "k8s-warn"
                                 (list "pvc" (k8s--name v) (k8s--ns-of v))))
               (filter (lambda (v) (not (equal? (k8s--js v 'status 'phase) "Bound")))
                       (k8s--items d "PersistentVolumeClaim")))))
    (append nodes spread hpas pods jobs pvcs)))
(define (k8s--emit-warnings d checks)
  (let* ((ev (hash-ref d 'events))
         (rows (if (null? ev) '() (k8s--last-n (cdr ev) *k8s-max-events*))))
    (section-open 'k8s-events (k8s--count-label "Warnings" (+ (length checks) (length rows))) "k8s-section")
    (when (and (null? checks) (null? rows)) (section-line "    (no warnings)" "k8s-dim"))
    (for-each (lambda (c) (k8s--emit-row "  " (list (car c) '()) (nth c 1) (nth c 2))) checks)
    (when (pair? rows)
      (when (pair? checks) (section-line "" #f))
      (section-line (string-append "  " (car ev)) "k8s-dim")
      (for-each (lambda (row) (section-line (string-append "  " row) "k8s-warn")) rows))
    (section-close 'k8s-events)
    (section-line "" #f)))

;; ── trends (lib-plot) ─────────────────────────────────────────────────────────
;; Cluster-average CPU / memory usage across refreshes, from `kubectl top nodes`.
;; Fills in as you refresh — auto-refresh (`a`) adds a sample every interval.
;; Y axis top: 100% would flatten a quiet cluster onto the axis, so zoom to
;; 1.5× the peak (rounded up to 10, at least 20, at most 100).
(define (k8s--trend-max vals)
  (let ((m (quotient (* 3 (apply max vals)) 2)))
    (min 100 (max 20 (* 10 (quotient (+ m 9) 10))))))
(define (k8s--emit-trends)
  (let ((cpu (k8s--hist "cluster-cpu")) (mem (k8s--hist "cluster-mem")))
    (section-open 'k8s-trends "Trends" "k8s-section")
    (if (< (length cpu) 2)
        (section-line (string-append "    (cluster usage chart — "
                                     (if (null? cpu) "needs metrics-server: `kubectl top` failed"
                                         "collecting samples; each refresh adds one, `a` auto-refreshes")
                                     ")")
                      "k8s-dim")
        (for-each
         (lambda (row)
           (let ((b (+ (section-point-byte) 4)))
             (section-line (string-append "    " (plot-row-text row)))
             (for-each (lambda (s) (section-accent (+ b (car s)) (+ b (cadr s)) (nth s 2)))
                       (plot-row-spans row))))
         (plot-lines (list (list "CPU %" cpu) (list "MEM %" mem))
                     'width 60 'height 6 'y-min 0 'y-max (k8s--trend-max (append cpu mem)) 'legend #t
                     'title (string-append "cluster avg usage · last " (k8s--str (length cpu)) " refreshes"))))
    (section-close 'k8s-trends)
    (section-line "" #f)))

;; ── header + render ───────────────────────────────────────────────────────────
(define (k8s--emit-header d checks)
  (let* ((ctx (k8s--st 'context))
         (line (string-append "Context: " (if (equal? ctx "") "(none)" ctx)
                              "    Namespace: " (if (k8s--st 'all-ns) "<all>" (k8s--st 'namespace))
                              (if (k8s--st 'auto) "    [auto-refresh]" "")))
         (took (if d (hash-ref d 'took) 0))
         (stamp (if d (string-append "    updated " (hash-ref d 'at) " in "
                                     (k8s--str (quotient took 1000)) "."
                                     (k8s--str (quotient (remainder took 1000) 100)) "s")
                    ""))
         (warn (if (pair? checks)
                   (string-append "    ▲ " (k8s--str (length checks)) " check"
                                  (if (= 1 (length checks)) "" "s") " — see Warnings")
                   ""))
         (b (utf8-length (string-append line stamp))))
    (k8s--accent-row (section-point-byte)
                     (list (list (utf8-length line) b "k8s-dim")
                           (list b (+ b (utf8-length warn)) "k8s-warn")))
    (section-line (string-append line stamp warn) "k8s-header")
    (section-line "  ? help · r refresh · TAB fold / expand · d describe · l logs · q quit" "k8s-dim")
    (when d
      (for-each (lambda (e) (section-line (string-append "  ✗ kubectl " e) "k8s-err"))
                (hash-ref d 'errors)))
    (section-line "" #f)))

;; Draw the dashboard from the cached 'data. `quiet` updates the buffer IN PLACE
;; without stealing focus (background auto-refresh while the user is in another
;; buffer) — like magit's quiet refresh, it skips fold/accent overlays, which
;; re-apply on the next in-front render. The interactive path preserves point
;; and re-applies folds.
(define (k8s--render-data quiet)
  (let ((line (if (equal? (current-buffer) "*k8s-dashboard*") (buffer-line) 0))
        (d (k8s--st 'data)))
    (k8s--st! 'now (k8s--now))
    (k8s--st! 'linemap '())
    (section-begin)
    (if (not d)
        (begin (k8s--emit-header #f '()) (section-line "  loading…" "k8s-dim"))
        (let* ((m (k8s--model d)) (checks (k8s--checks d m)))
          (k8s--emit-header d checks)
          (k8s--emit-nodes d m)
          (k8s--emit-workloads d m)
          (k8s--emit-hpas d)
          (k8s--emit-jobs d m)
          (k8s--emit-pods d m)
          (k8s--emit-services d m)
          (k8s--emit-ingresses d)
          (k8s--emit-volumes d m)
          (k8s--emit-warnings d checks)
          (k8s--emit-trends)))
    (if quiet
        (render-buffer-quiet "*k8s-dashboard*" "k8s-mode" (section-text) (section-line-faces))
        (begin
          (section-render "*k8s-dashboard*" "k8s-mode")
          (goto-line line)))))

;; `r`: fetch, then redraw when the queries come back (in place, point kept).
(define-command (k8s-refresh)
  (if (k8s--fetch-busy?)
      (begin (k8s--st! 'queued #t) (message "k8s: refresh already running — queued another"))
      (k8s--fetch)))

;; ── the entry command ─────────────────────────────────────────────────────────
;; Show the dashboard right away (cached data, or "loading…" the first time),
;; then fetch.
(define-command (k8s-dashboard)
  (k8s--resolve-context!)
  (when (not (k8s--st 'ns-resolved))
    (k8s--resolve-namespace!)
    (k8s--st! 'ns-resolved #t))
  (k8s--render-data #f)
  (k8s--fetch))

;; ── navigation / fold ─────────────────────────────────────────────────────────
;; TAB: expand/collapse a multi-container pod or a job's earlier runs (a
;; re-render from cache), else fold the section at point.
(define-command (k8s-toggle-fold)
  (let* ((r (k8s--resource-at)) (key (and r (k8s--nth-or r 5 #f))))
    (if key
        (begin (k8s--toggle-expanded! key) (k8s--render-data #f))
        (section-toggle-at-point))))

;; The resource on the current line, as (line kind name ns [container key]), or #f.
(define (k8s--resource-at)
  (let ((ln (buffer-line)))
    (let loop ((m (k8s--st 'linemap)))
      (cond ((null? m) #f)
            ((= (car (car m)) ln) (car m))
            (else (loop (cdr m)))))))
(define (k8s--container-of r) (k8s--nth-or r 4 #f))
(define (k8s--require-kind r kinds what)
  (if (and r (member (nth r 1) (if (list? kinds) kinds (list kinds)))) #t
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
    (if (and r (not (equal? (nth r 1) "more")))
        (begin (clipboard-set (nth r 2)) (message (string-append "Copied " (nth r 2))))
        (k8s-copy-line))))

;; ── describe / yaml ───────────────────────────────────────────────────────────
(define (k8s--resource? r) (and r (not (equal? (nth r 1) "more"))))
(define-command (k8s-describe)
  (let ((r (k8s--resource-at)))
    (if (k8s--resource? r)
        (let ((out (k8s--run (append (list "describe" (nth r 1) (nth r 2))
                                     (k8s--ns-args-for r)))))
          (render-buffer "*k8s-describe*" "k8s-detail-mode"
                         (if (k8s--blank? out) "(no output)" (trim-end out)) '()))
        (message "k8s: point is not on a resource"))))

;; YAML opens in a REAL file buffer (a temp `.yaml`), not a special render-buffer,
;; so it auto-detects into yaml highlighting AND every keymap works normally —
;; evil/helix/emacs motion, `/` search, native `yy` yank, the lot. A render-buffer
;; is "special" and only gets the motion overlay, so search etc. wouldn't work.
(define (k8s--yaml-slug ns kind name)
  (string-append (if (equal? ns "") "cluster" ns) "-" kind "-" name ".yaml"))
(define-command (k8s-yaml)
  (let ((r (k8s--resource-at)))
    (if (k8s--resource? r)
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
;; On a container row (an expanded pod), that container's logs.
(define-command (k8s-logs)
  (let ((r (k8s--resource-at)))
    (when (k8s--require-kind r "pod" "pod for logs")
      (let* ((name (nth r 2)) (c (k8s--container-of r))
             (out (k8s--run (append (list "logs" (string-append "--tail=" (number->string *k8s-log-tail*))
                                          "-n" (nth r 3) name)
                                    (if c (list "-c" c) '())))))
        (render-buffer (string-append "*k8s-logs:" name (if c (string-append "/" c) "") "*")
                       "k8s-detail-mode"
                       (if (k8s--blank? out) "(no logs)" (trim-end out)) '())))))

;; ── shell (kubectl exec -it, in a half-screen terminal) ───────────────────────
;; `s`: split the dashboard window in half and run an interactive shell inside the
;; pod in the new bottom pane. Focus follows the `k8s-shell-focus` option (the
;; terminal by default, so you can type). `S`: the same shell, full-window (it
;; replaces the dashboard in this window; `C-x b` goes back). On a container row,
;; the shell runs in that container.
;;
;; A terminal sends almost every key to the shell. What still reaches the editor:
;; `C-x` (`C-x o` other pane, `C-x 1` only this pane, `C-x k` kill), your evil
;; leader chords via the ALT leader (`M-SPC n o` = your `SPC n o`), and any chord
;; in the `terminal-passthrough-keys` option. When the shell exits, its pane and
;; buffer close on their own (see k8s--on-terminal-exit).
(define k8s--shell-prefix "*k8s-shell:")
(define (k8s--open-shell pod ns container full)
  (let ((sh (k8s--shell))
        (stay (and (not full) (k8s--shell-focus-dashboard?))))
    (when (not full)
      (split-window-below)                   ; half-height pane across the bottom
      (other-window))                        ; the terminal opens in the new pane
    (make-terminal (string-append k8s--shell-prefix pod (if container (string-append "/" container) "") "*")
                   *k8s-command*
                   (append (list "exec" "-it" pod "-n" ns)
                           (if container (list "-c" container) '())
                           (list "--" sh))
                   "")                       ; "" → the active buffer's directory
    (when stay (other-window))               ; back to the dashboard pane
    (message (string-append "shell → " pod (if container (string-append "/" container) "")
                            " (" ns ") : " sh
                            (if stay "  ·  C-x o to enter it" "")))))
(define-command (k8s-shell)
  (let ((r (k8s--resource-at)))
    (when (k8s--require-kind r "pod" "pod to open a shell")
      (k8s--open-shell (nth r 2) (nth r 3) (k8s--container-of r) #f))))
(define-command (k8s-shell-full)
  (let ((r (k8s--resource-at)))
    (when (k8s--require-kind r "pod" "pod to open a shell")
      (k8s--open-shell (nth r 2) (nth r 3) (k8s--container-of r) #t))))

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

;; ── scale (deployments, statefulsets) ─────────────────────────────────────────
(define k8s--scalable (list "deployment" "statefulset"))
(define-command (k8s-scale)
  (let ((r (k8s--resource-at)))
    (when (k8s--require-kind r k8s--scalable "deployment or statefulset to scale")
      (let ((kind (nth r 1)) (name (nth r 2)) (ns (nth r 3)))
        (read-string (string-append "Scale " kind "/" name " to replicas: ")
                     (lambda (input) (k8s--scale-to kind name ns input)))))))
;; `s` is context-sensitive: a shell on a pod, scale on a deployment/statefulset.
(define-command (k8s-shell-or-scale)
  (let ((r (k8s--resource-at)))
    (cond ((and r (equal? (nth r 1) "pod"))
           (k8s--open-shell (nth r 2) (nth r 3) (k8s--container-of r) #f))
          ((and r (member (nth r 1) k8s--scalable)) (k8s-scale))
          (else (message "k8s: 's' opens a shell on a pod or scales a deployment/statefulset")))))
(define (k8s--scale-to kind name ns input)
  (let ((n (trim-end (trim-start input))))
    (when (not (equal? n ""))
      (let ((res (k8s--run-full (list "scale" (string-append kind "/" name)
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
  (let ((res (k8s--run-full (list "delete" "pod" name "-n" ns "--wait=false"))))
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
;; with `(set-option "k8s-node-group-label" …)`; this command adds M-x + redraw.
(define (k8s--apply-node-group-label label)
  (let ((lbl (trim-end (trim-start label))))
    (set-option "k8s-node-group-label" lbl)
    (message (string-append "k8s: node grouping by " (if (equal? lbl "") "(auto)" lbl)))
    (when (equal? (current-buffer) "*k8s-dashboard*") (k8s--render-data #f))))
(define-command (k8s-set-node-group-label . rest)
  (if (null? rest)
      (read-string "Node group label (empty = auto): " k8s--apply-node-group-label)
      (k8s--apply-node-group-label (car rest))))
;; A new context is a different cluster: drop the cached data and usage history.
(define-command (k8s-set-context)
  (completing-read "Context: " (k8s--contexts)
    (lambda (ctx) (when (not (k8s--blank? ctx))
                    (k8s--run (list "config" "use-context" (trim-end ctx)))
                    (k8s--resolve-context!)
                    (k8s--resolve-namespace!)
                    (k8s--st! 'data #f) (k8s--st! 'hist #f) (k8s--st! 'expanded '())
                    (k8s--render-data #f)
                    (k8s-refresh)))))

;; ── dispatch popup (?) ────────────────────────────────────────────────────────
;; `?` opens a transient of the actions available on the resource under point;
;; anywhere else, the view menu plus a key reference. The popup closes on a key
;; and runs its command, which re-reads point (still on the same row), so the
;; existing action commands work unchanged.
(define (k8s--inspect-group)
  (list "Inspect" (list "d" "Describe" 'k8s-describe) (list "y" "YAML" 'k8s-yaml)
        (list "shift-y" "Copy name" 'k8s-copy)))
(define-command (k8s-dispatch)
  (let* ((r (k8s--resource-at))
         (kind (and (k8s--resource? r) (nth r 1)))
         (title (and kind (string-append kind ": " (nth r 2)
                                         (if (k8s--container-of r) (string-append " / " (k8s--container-of r)) "")
                                         (if (equal? (nth r 3) "") "" (string-append "  (" (nth r 3) ")"))))))
    (cond
     ((equal? kind "pod")
      (transient title
        (list (list "Inspect"
                    (list "d" "Describe"       'k8s-describe)
                    (list "y" "YAML"           'k8s-yaml)
                    (list "l" "Logs"           'k8s-logs)
                    (list "tab" "Containers"   'k8s-toggle-fold))
              (list "Act"
                    (list "s" "Shell"          'k8s-shell)
                    (list "shift-s" "Shell (full window)" 'k8s-shell-full)
                    (list "x" "Delete"         'k8s-delete)
                    (list "q" "Close"          'transient-quit)))))
     ((member kind k8s--scalable)
      (transient title
        (list (k8s--inspect-group)
              (list "Act"
                    (list "s" "Scale"          'k8s-scale)
                    (list "q" "Close"          'transient-quit)))))
     (kind
      (transient title
        (list (append (k8s--inspect-group) (list (list "q" "Close" 'transient-quit))))))
     (else
      (transient "Kubernetes"
        (list (list "View"
                    (list "r" "Refresh"          'k8s-refresh)
                    (list "shift-n" "Namespace"  'k8s-set-namespace)
                    (list "shift-a" "All namespaces" 'k8s-toggle-all-namespaces)
                    (list "shift-c" "Context"    'k8s-set-context)
                    (list "a" "Auto-refresh"     'k8s-toggle-auto)
                    (list "q" "Close"            'transient-quit))
              (list "On a resource row"
                    (list "d" "Describe"         'k8s-describe)
                    (list "y" "YAML"             'k8s-yaml)
                    (list "l" "Logs (pod)"       'k8s-logs)
                    (list "s" "Shell / scale"    'k8s-shell-or-scale)
                    (list "shift-s" "Full shell" 'k8s-shell-full)
                    (list "x" "Delete (pod)"     'k8s-delete)
                    (list "shift-y" "Copy name"  'k8s-copy))))))))

;; ── auto-refresh polling ──────────────────────────────────────────────────────
;; A single self-rearming timer. Each tick starts a fetch (skipped while one is
;; still running); when it lands, the dashboard redraws normally if it's in front
;; (point preserved) or SILENTLY in place if the user is in another buffer —
;; never swapping focus back to it. The chain stops once the dashboard buffer is
;; gone or auto-refresh is toggled off.
(define (k8s--arm-timer)
  (when (not (k8s--st 'timer-armed))
    (k8s--st! 'timer-armed #t)
    (run-with-timer *k8s-auto-refresh-ms* "k8s--tick")))
(define-command (k8s--tick)
  (k8s--st! 'timer-armed #f)
  (when (and (k8s--st 'auto) (member "*k8s-dashboard*" (buffer-names)))
    (when (not (k8s--fetch-busy?)) (k8s--fetch))
    (k8s--arm-timer)))
(define-command (k8s-toggle-auto)
  (k8s--st! 'auto (not (k8s--st 'auto)))
  (if (k8s--st 'auto)
      (begin (message (string-append "k8s: auto-refresh on ("
                                     (number->string (quotient *k8s-auto-refresh-ms* 1000)) "s)"))
             (k8s--arm-timer))
      (message "k8s: auto-refresh off"))
  (when (equal? (current-buffer) "*k8s-dashboard*") (k8s--render-data #f)))

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
(define-key "k8s-mode" "s" 'k8s-shell-or-scale)   ; pod → shell, deployment/sts → scale
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
