;;; test/benedict-http-test.el --- Tests for benedict-http  -*- lexical-binding: t; -*-

(require 'ert)
(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-http)

(ert-deftest benedict-http-command-generation ()
  "Test curl command generation."
  (let ((benedict-http-curl-program "curl")
        (benedict-http-proxy-args '("--proxy" "http://localhost:8080")))
    (let ((cmd (benedict-http--make-command
                "https://example.com" "POST"
                '(("Content-Type" . "application/json")
                  ("Authorization" . "Bearer token"))
                "{\"foo\":\"bar\"}"
                t)))
      (should (equal (car cmd) "curl"))
      (should (member "--no-buffer" cmd))
      (should (member "--fail-with-body" cmd))
      (should (member "https://example.com" cmd))
      (should (member "--proxy" cmd))
      (should (member "http://localhost:8080" cmd))
      ;; Headers
      (should (member "-H" cmd))
      (should (member "Content-Type: application/json" cmd))
      (should (member "Authorization: Bearer token" cmd))
      (should (member "Accept: text/event-stream" cmd))
      ;; Body
      (should (member "--data-binary" cmd))
      (should (member "{\"foo\":\"bar\"}" cmd)))))

(ert-deftest benedict-http-sse-parsing ()
  "Test SSE block parsing."
  (let ((delta-calls nil))
    (let ((context (list :on-delta (lambda (type data)
                                     (push (list type data) delta-calls))
                         :provider 'test
                         :request-id "req1")))
      (benedict-http--process-sse-block context "data: hello\n\n")
      (should (equal (pop delta-calls) '(nil "hello")))
      
      (benedict-http--process-sse-block context "event: update\ndata: world\n\n")
      (should (equal (pop delta-calls) '("update" "world")))
      
      ;; Multiline data
      (benedict-http--process-sse-block context "data: line1\ndata: line2\n\n")
      (should (equal (pop delta-calls) '(nil "line1\nline2"))))))

(ert-deftest benedict-http-chunk-handling ()
  "Test stream chunk accumulation."
  (let ((delta-calls nil))
    (let ((context (list :on-delta (lambda (type data)
                                     (push (list type data) delta-calls))
                         :provider 'test
                         :request-id "req1"
                         :partial ""
                         :stream t)))
      
      ;; Partial chunk
      (benedict-http--handle-stream-chunk context "data: part1")
      (should (equal (plist-get context :partial) "data: part1"))
      (should (null delta-calls))
      
      ;; Complete the chunk
      (benedict-http--handle-stream-chunk context "\n\n")
      (should (equal (plist-get context :partial) ""))
      (should (equal (pop delta-calls) '(nil "part1")))
      
      ;; Multiple chunks in one
      (benedict-http--handle-stream-chunk context "data: A\n\ndata: B\n\n")
      (should (equal (plist-get context :partial) ""))
      (should (equal (pop delta-calls) '(nil "B")))
      (should (equal (pop delta-calls) '(nil "A"))))))

(provide 'test/benedict-http-test)
;;; benedict-http-test.el ends here
