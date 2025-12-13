;;; test/benedict-agent-loop-test.el --- Tests for Agent Loop & Safeguards -*- lexical-binding: t; -*-

(require 'ert)
(require 'benedict-chat)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

;; -------------------------------------------------------------------
;; Mocking infrastructure
;; -------------------------------------------------------------------

(defvar benedict-test--last-dispatch-call nil)
(defvar benedict-test--last-y-or-n-prompt nil)
(defvar benedict-test--y-or-n-response t)

(defun benedict-test--mock-start-dispatch (request &optional retry)
  "Mock dispatch by storing REQUEST."
  (setq benedict-test--last-dispatch-call (list :request request :retry retry)))

(defun benedict-test--mock-y-or-n-p (prompt)
  "Mock y-or-n-p by storing PROMPT and returning `benedict-test--y-or-n-response'."
  (setq benedict-test--last-y-or-n-prompt prompt)
  benedict-test--y-or-n-response)

;; -------------------------------------------------------------------
;; Loop Step & Recursion Tests
;; -------------------------------------------------------------------

(ert-deftest benedict-loop-recurses-on-tool-calls ()
  "Loop should recurse (dispatch) when tool calls are present."
  (let ((benedict-chat--loop-turn-count 0)
        (benedict-chat--messages nil)
        (benedict-test--last-dispatch-call nil))
    (cl-letf (((symbol-function 'benedict-chat--start-dispatch) #'benedict-test--mock-start-dispatch)
              ((symbol-function 'benedict-chat--build-request) (lambda () '(:mock-request t)))
              ((symbol-function 'benedict-chat--check-loop-constraints) (lambda () t)))
      
      (benedict-chat--loop-step '(:role assistant :tool-calls ((:name "test"))))
      
      (should (equal benedict-test--last-dispatch-call '(:request (:mock-request t) :retry nil)))
      (should (= benedict-chat--loop-turn-count 1)))))

(ert-deftest benedict-loop-stops-on-no-tool-calls ()
  "Loop should NOT recurse when no tool calls are present."
  (let ((benedict-chat--loop-turn-count 0)
        (benedict-test--last-dispatch-call nil))
    (cl-letf (((symbol-function 'benedict-chat--start-dispatch) #'benedict-test--mock-start-dispatch))
      (benedict-chat--loop-step '(:role assistant :content "Done."))
      (should (null benedict-test--last-dispatch-call))
      (should (= benedict-chat--loop-turn-count 0)))))

;; -------------------------------------------------------------------
;; Safeguard Tests
;; -------------------------------------------------------------------

(ert-deftest benedict-safeguard-checkpoint-prompts ()
  "Checkpoint should prompt user when interval is reached."
  (let ((benedict-chat-loop-checkpoint-interval 5)
        (benedict-chat--loop-turn-count 5)
        (benedict-chat--loop-start-time (float-time))
        (benedict-test--y-or-n-response t)
        (benedict-test--last-y-or-n-prompt nil))
    (cl-letf (((symbol-function 'y-or-n-p) #'benedict-test--mock-y-or-n-p))
      ;; Should prompt "run 5 autonomous steps"
      (should (benedict-chat--check-loop-constraints))
      (should (string-match-p "run 5 autonomous steps" benedict-test--last-y-or-n-prompt)))))

(ert-deftest benedict-safeguard-checkpoint-stops-on-no ()
  "Checkpoint should return nil (stop) when user says no."
  (let ((benedict-chat-loop-checkpoint-interval 5)
        (benedict-chat--loop-turn-count 5)
        (benedict-test--y-or-n-response nil))
    (cl-letf (((symbol-function 'y-or-n-p) #'benedict-test--mock-y-or-n-p))
      (should-not (benedict-chat--check-loop-constraints)))))

(ert-deftest benedict-safeguard-time-limit ()
  "Time limit should prompt when exceeded."
  (let ((benedict-chat-loop-max-time 1.0)
        (benedict-chat--loop-start-time (- (float-time) 2.0)) ;; Started 2s ago
        (benedict-test--y-or-n-response t)
        (benedict-test--last-y-or-n-prompt nil))
    (cl-letf (((symbol-function 'y-or-n-p) #'benedict-test--mock-y-or-n-p))
      (should (benedict-chat--check-loop-constraints))
      (should (string-match-p "Time limit.*reached" benedict-test--last-y-or-n-prompt))
      ;; Accepting the prompt should reset the loop window.
      (should (> benedict-chat--loop-start-time (- (float-time) 5.0))))))

(ert-deftest benedict-safeguard-repetition-guard ()
  "Repetition guard should detect identical consecutive tool calls."
  ;; We need TWO assistant messages to compare:
  ;; 1. The "current" one (most recent in history)
  ;; 2. The "previous" one
  (let ((history '((:role assistant :tool-calls ((:name "foo" :args (:x 1)))) ;; Current
                   (:role user :content "output")
                   (:role assistant :tool-calls ((:name "foo" :args (:x 1)))) ;; Previous
                   (:role user :content "input"))))
    ;; Same call -> t
    (should (benedict-chat--check-repetition-guard 
             '((:name "foo" :args (:x 1))) history))
    
    ;; Different args -> nil (simulate current call changing)
    (should-not (benedict-chat--check-repetition-guard 
                 '((:name "foo" :args (:x 2))) history))
                 
    ;; Different tool -> nil
    (should-not (benedict-chat--check-repetition-guard 
                 '((:name "bar" :args (:x 1))) history))))

(ert-deftest benedict-loop-canceled-check ()
  "Constraints should return nil immediately if canceled flag is set."
  (let ((benedict-chat--loop-canceled t))
    (should-not (benedict-chat--check-loop-constraints))))


(ert-deftest benedict-safeguard-layered-autonomy ()
  "Profile limits should override global limits if stricter."
  (let ((benedict-chat-profiles
         '((restricted :label "Restricted"
                       :autonomy (:max-turns 2 :max-time 10.0))))
        (benedict-chat-profile 'restricted)
        (benedict-chat-loop-checkpoint-interval 100) ;; Loose global
        (benedict-chat-loop-max-time 100.0)          ;; Loose global
        (benedict-chat--loop-turn-count 2)
        (benedict-chat--loop-start-time (float-time))
        (benedict-test--y-or-n-response t)
        (benedict-test--last-y-or-n-prompt nil))
    
    (cl-letf (((symbol-function 'y-or-n-p) #'benedict-test--mock-y-or-n-p))
      ;; Should prompt because turn count 2 matches profile limit 2
      ;; Global limit is 100, so effective limit is min(100, 2) = 2.
      (should (benedict-chat--check-loop-constraints))
      (should (string-match-p "run 2 autonomous steps" benedict-test--last-y-or-n-prompt))
      
      ;; Now check time limit
      (setq benedict-test--last-y-or-n-prompt nil)
      ;; Advance time by 11 seconds (limit is 10s, global 100s)
      (setq benedict-chat--loop-start-time (- (float-time) 11.0))
      (should (benedict-chat--check-loop-constraints))
      (should (string-match-p "Time limit.*reached" benedict-test--last-y-or-n-prompt))
      (should (> benedict-chat--loop-start-time (- (float-time) 5.0))))))

(ert-deftest benedict-safeguard-layered-autonomy-global-wins ()
  "Global limits should override profile limits if stricter."
  (let ((benedict-chat-profiles
         '((loose :label "Loose"
                  :autonomy (:max-turns 100))))
        (benedict-chat-profile 'loose)
        (benedict-chat-loop-checkpoint-interval 5) ;; Strict global
        (benedict-chat--loop-turn-count 5)
        (benedict-test--y-or-n-response t)
        (benedict-test--last-y-or-n-prompt nil))
    
    (cl-letf (((symbol-function 'y-or-n-p) #'benedict-test--mock-y-or-n-p))
      ;; Should prompt at 5 (global limit), not 100 (profile limit)
      (should (benedict-chat--check-loop-constraints))
      (should (string-match-p "run 5 autonomous steps" benedict-test--last-y-or-n-prompt)))))

(ert-deftest benedict-safeguard-layered-autonomy-fallback ()
  "Profile with no limit falls back to global."
  (let ((benedict-chat-profiles
         '((normal :label "Normal"))) ;; No autonomy key
        (benedict-chat-profile 'normal)
        (benedict-chat-loop-checkpoint-interval 5)
        (benedict-chat--loop-turn-count 5)
        (benedict-test--y-or-n-response t)
        (benedict-test--last-y-or-n-prompt nil))
    
    (cl-letf (((symbol-function 'y-or-n-p) #'benedict-test--mock-y-or-n-p))
      (should (benedict-chat--check-loop-constraints))
      (should (string-match-p "run 5 autonomous steps" benedict-test--last-y-or-n-prompt)))))

(provide 'test/benedict-agent-loop-test)
;;; benedict-agent-loop-test.el ends here
