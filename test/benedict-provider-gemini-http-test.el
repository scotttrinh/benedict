;;; test/benedict-provider-gemini-http-test.el --- Tests for Gemini HTTP parsing -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)

(let* ((root (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name ".." root)))
  (add-to-list 'load-path repo))

(require 'benedict-provider-gemini)

(ert-deftest benedict-provider-gemini-token-request-parsing ()
  "Verify that benedict-provider-gemini--token-request correctly parses HTTP status and body."
  (message "RUNNING benedict-provider-gemini-token-request-parsing")
  (let ((response-content (concat "HTTP/1.1 200 OK\n"
                                  "Pragma: no-cache\n"
                                  "Cache-Control: no-cache, no-store, max-age=0, must-revalidate\n"
                                  "Content-Type: application/json; charset=utf-8\n"
                                  "\n"
                                  "{\"access_token\": \"fake-token\"}")))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (let ((buf (get-buffer-create " *gemini-mock-response*")))
                   (with-current-buffer buf
                     (erase-buffer)
                     (insert response-content))
                   buf))))
      (let ((result (benedict-provider-gemini--token-request "any-body")))
        (should (equal (plist-get result :status) 200))
        (should (string-match-p "fake-token" (plist-get result :body)))))))

(provide 'test/benedict-provider-gemini-http-test)
;;; benedict-provider-gemini-http-test.el ends here
