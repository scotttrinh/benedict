;;; benedict-vui-conversation-view-test.el --- Tests for VUI conversation view -*- lexical-binding: t; -*-

;;; Commentary:
;; Focused tests for conversation view wrapper behavior.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'vui)
(require 'test/benedict-vui-test-utils)
(require 'benedict-turn)
(require 'benedict-vui-conversation-view)
(require 'benedict-vui-streaming-indicator)

(ert-deftest benedict-vui-conversation-view-streaming-active-p ()
  "Streaming helper identifies active state from active-turn state."
  (should (benedict-vui-conversation-view--streaming-active-p
           (benedict-turn-create "session-1" :state 'running)))
  (should (not (benedict-vui-conversation-view--streaming-active-p
                (benedict-turn-create "session-1" :state 'turn-complete))))
  (should (not (benedict-vui-conversation-view--streaming-active-p
                (benedict-turn-create "session-1" :state 'idle))))
  (should (not (benedict-vui-conversation-view--streaming-active-p nil))))

(provide 'test/benedict-vui-conversation-view-test)
;;; benedict-vui-conversation-view-test.el ends here
