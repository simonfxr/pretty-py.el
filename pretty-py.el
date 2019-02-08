;;; pretty-py.el --- Format Python code using yapf, autopep8 or black -*- lexical-binding: t; -*-

;;; Commentary:

;; This file is an adaption of code from go-mode.el
;; see https://github.com/dominikh/go-mode.el
;; Copyright 2019 Simon Reiser
;; Copyright 2013 the go-mode Authors.  All rights reserved.
;; Use of this source code is governed by a BSD-style
;; license that can be found in the LICENSE file.

;; Author: Simon Reiser, the go-mode Authors
;; Version: 0.1.0
;; Keywords: languages python yapf black
;; Package-Requires: ((emacs "25.1"))
;; URL: https://github.com/simonfxr/pretty-py.el
;;
;; This file is not part of GNU Emacs.

;;; Code:

(require 'url)

(defcustom pretty-py-formatter 'yapf
  "Configure your preferred-formatter to use with `pretty-py-buffer'."
  :type '(choice
          (const :tag "yapf" yapf)
          (const :tag "autopep8" autopep8)
          (const :tag "black" black))
  :group 'pretty-py)

(defcustom pretty-py-autopep8-command "autopep8"
  "The 'autopep8' command."
  :type 'string
  :group 'pretty-py)

(defcustom pretty-py-autopep8-args ()
  "Additional arguments to pass to autopep8."
  :type '(repeat string)
  :group 'pretty-py)

(defcustom pretty-py-yapf-command "yapf"
  "The 'yapf' command."
  :type 'string
  :group 'pretty-py)

(defcustom pretty-py-yapf-args ()
  "Additional arguments to pass to yapf."
  :type '(repeat string)
  :group 'pretty-py)

(defcustom pretty-py-black-command "black"
  "The 'black' command."
  :type 'string
  :group 'pretty-py)

(defcustom pretty-py-black-args ()
  "Additional arguments to pass to black.
Cannot be passed when using the HTTP daemon."
  :type '(repeat string)
  :group 'pretty-py)

(defcustom pretty-py-blackd-command "blackd"
  "The 'blackd' command."
  :type 'string
  :group 'pretty-py)

(defcustom pretty-py-black-fast-flag t
  "Non-nil means to pass --fast to black/blackd."
  :type 'boolean
  :group 'pretty-py)

(defcustom pretty-py-black-line-length nil
  "If set, pass --line-length=x to black/blackd."
  :type '(choice
          (integer :tag "Fixed line length")
          (const :tag "Automatic" nil))
  :group 'pretty-py)

(defcustom pretty-py-use-blackd nil
  "Non-nil means to prefer the blackd HTTP daemon over the command line program.
This flag is only relevant when black is used for formatting."
  :type 'boolean
  :group 'pretty-py)

(defcustom pretty-py-blackd-startup-wait-seconds nil
  "The amount of time to wait for blackd to startup before sending the first request."
  :type 'integer
  :group 'pretty-py)

(defcustom pretty-py-blackd-request-timeout-seconds 5
  "Timeout when making requests to blackd."
  :type 'integer
  :group 'pretty-py)

(defcustom pretty-py-blackd-host "localhost"
  "The address where blackd will listen."
  :type 'string
  :group 'pretty-py)

(defcustom pretty-py-blackd-port 45484
  "The port where blackd will listen."
  :type 'integer
  :group 'pretty-py)

(defcustom pretty-py-show-errors 'buffer
  "Where to display formatter error output.
It can either be displayed in its own buffer, in the echo area,
or not at all. Please note that Emacs outputs to the echo area
when writing files and will overwrite the formatter's echo output
if used from inside a `before-save-hook'."
  :type '(choice
          (const :tag "Own buffer" buffer)
          (const :tag "Echo area" echo)
          (const :tag "None" nil))
  :group 'pretty-py)

(defvar pretty-py--blackd-process nil)

(defun pretty-py--apply-rcs-patch (patch-buffer)
  "Apply an RCS-formatted diff from PATCH-BUFFER to the current buffer."
  (let ((target-buffer (current-buffer))
        ;; Relative offset between buffer line numbers and line numbers
        ;; in patch.
        ;;
        ;; Line numbers in the patch are based on the source file, so
        ;; we have to keep an offset when making changes to the
        ;; buffer.
        ;;
        ;; Appending lines decrements the offset (possibly making it
        ;; negative), deleting lines increments it. This order
        ;; simplifies the forward-line invocations.
        (line-offset 0)
        (column (current-column)))
    (save-excursion
      (with-current-buffer patch-buffer
        (goto-char (point-min))
        (while (not (eobp))
          (unless (looking-at "^\\([ad]\\)\\([0-9]+\\) \\([0-9]+\\)")
            (error "Invalid rcs patch or internal error in pretty-py--apply-rcs-patch"))
          (forward-line)
          (let ((action (match-string 1))
                (from (string-to-number (match-string 2)))
                (len  (string-to-number (match-string 3))))
            (cond
             ((equal action "a")
              (let ((start (point)))
                (forward-line len)
                (let ((text (buffer-substring start (point))))
                  (with-current-buffer target-buffer
                    (decf line-offset len)
                    (goto-char (point-min))
                    (forward-line (- from len line-offset))
                    (insert text)))))
             ((equal action "d")
              (with-current-buffer target-buffer
                (pretty-py--goto-line (- from line-offset))
                (incf line-offset len)
                (pretty-py--delete-whole-line len)))
             (t
              (error "Invalid rcs patch or internal error in pretty-py--apply-rcs-patch")))))))
    (move-to-column column)))

;;;###autoload
(defun pretty-py-buffer ()
  "Format the current buffer according to the formatting tool."
  (interactive)
  (let ((tmp-file (make-nearby-temp-file "pretty-py-" nil ".py.tmp"))
        (patch-buf (get-buffer-create "*pretty-py patch*"))
        (err-buf (if pretty-py-show-errors (get-buffer-create "*pretty-py errors*")))
        (coding-system-for-read 'utf-8)
        (coding-system-for-write 'utf-8)
        (tool-name (symbol-name pretty-py-formatter))
        ret)

    (unwind-protect
        (save-restriction
          (widen)
          (if err-buf
              (with-current-buffer err-buf
                (setq buffer-read-only nil)
                (erase-buffer)))
          (with-current-buffer patch-buf
            (erase-buffer))

          (setq ret
                (if (and (eq pretty-py-formatter 'black) pretty-py-use-blackd)
                    (pretty-py--via-http
                     (buffer-substring (point-min) (point-max))
                     tmp-file
                     err-buf)
                  (write-region nil nil tmp-file)
                  (pretty-py--via-program tmp-file err-buf)))

          (case ret
            (no-change (message "Buffer is already formatted"))
            ((nil) (message "Running %s failed" tool-name)
                 (when err-buf
                   (pretty-py--process-errors
                    tool-name (buffer-file-name) tmp-file err-buf)))
            (t
             (if (zerop (let ((local-copy (file-local-copy tmp-file)))
                          (unwind-protect
                              (call-process-region
                               (point-min) (point-max) "diff" nil patch-buf
                               nil "-n" "-" (or local-copy tmp-file))
                            (when local-copy (delete-file local-copy)))))
                 (message "Buffer is already formatted")
               (pretty-py--apply-rcs-patch patch-buf)
               (message "Formatted with %s" tool-name))))

          (when (and ret err-buf)
            (pretty-py--kill-error-buffer err-buf)))

      (kill-buffer patch-buf)
      (delete-file tmp-file))))

;;;###autoload
(defun pretty-py-buffer-yapf ()
  "Format the current buffer according to the yapf formatting tool."
  (interactive)
  (let ((pretty-py-formatter 'yapf))
    (pretty-py-buffer)))

;;;###autoload
(defun pretty-py-buffer-autopep8 ()
  "Format the current buffer according to the autopep8 formatting tool."
  (interactive)
  (let ((pretty-py-formatter 'autopep8))
    (pretty-py-buffer)))

;;;###autoload
(defun pretty-py-buffer-black ()
  "Format the current buffer according to the black formatting tool."
  (interactive)
  (let ((pretty-py-formatter 'black))
    (pretty-py-buffer)))

(defun pretty-py--process-errors (fmt-tool-name filename tmp-file err-buf)
  "Post process errors to ERR-BUF in TMP-FILE from running FMT-TOOL-NAME on FILENAME."
  (with-current-buffer err-buf
    (if (eq pretty-py-show-errors 'echo)
        (progn
          (message "%s" (buffer-string))
          (pretty-py--kill-error-buffer err-buf))
      ;; Convert stderr to something understood by the compilation mode.
      (goto-char (point-min))
      (insert (format "%s errors:\n" fmt-tool-name))
      (let ((truefile tmp-file))
        (while (search-forward-regexp
                (concat "^\\(" (regexp-quote (file-local-name truefile))
                        "\\):")
                nil t)
          (replace-match (file-name-nondirectory filename) t t nil 1)))
      (compilation-mode)
      (display-buffer err-buf))))

(defun pretty-py--kill-error-buffer (err-buf)
  "Hide Window showing ERR-BUF and kill the buffer."
  (let ((win (get-buffer-window err-buf)))
    (if win
        (quit-window t win)
      (kill-buffer err-buf))))

(defun pretty-py--goto-line (line)
  "Like (goto-line LINE) but zero based."
  (goto-char (point-min))
  (forward-line (1- line)))

(defun pretty-py--delete-whole-line (&optional arg)
  "Delete the current line without putting it in the `kill-ring'.
Derived from function `kill-whole-line'.  ARG is defined as for that
function."
  (setq arg (or arg 1))
  (if (and (> arg 0)
           (eobp)
           (save-excursion (forward-visible-line 0) (eobp)))
      (signal 'end-of-buffer nil))
  (if (and (< arg 0)
           (bobp)
           (save-excursion (end-of-visible-line) (bobp)))
      (signal 'beginning-of-buffer nil))
  (cond ((zerop arg)
         (delete-region (progn (forward-visible-line 0) (point))
                        (progn (end-of-visible-line) (point))))
        ((< arg 0)
         (delete-region (progn (end-of-visible-line) (point))
                        (progn (forward-visible-line (1+ arg))
                               (unless (bobp)
                                 (backward-char))
                               (point))))
        (t
         (delete-region (progn (forward-visible-line 0) (point))
                        (progn (forward-visible-line arg) (point))))))


(defun pretty-py--ensure-blackd ()
  "Start blackd on demand if it is not yet running."
  (unless (and pretty-py--blackd-process
               (process-live-p pretty-py--blackd-process))
    (let ((process-connection-type nil))
      (setq pretty-py--blackd-process
            (start-process
             "blackd" "*blackd*" pretty-py-blackd-command
             "--bind-host" pretty-py-blackd-host
             "--bind-port" (number-to-string pretty-py-blackd-port))))
    (set-process-query-on-exit-flag pretty-py--blackd-process nil)
    'started))

;;;###autoload
(defun pretty-py-stop-blackd ()
  "Stop the blackd daemon if it is running."
  (interactive)
  (when pretty-py--blackd-process
    (delete-process pretty-py--blackd-process)
    (ignore-errors (kill-buffer "*blackd*"))
    (setq pretty-py--blackd-process nil)))

(defun pretty-py--via-http (contents out-file err-buf)
  "Make a http request to blackd formatting CONTENTS to OUT-FILE, errors appear in ERR-BUF."
  (if (eq (pretty-py--ensure-blackd) 'just-started)
      ;; allow daemon to startup
      (sleep-for 'pretty-py-blackd-startup-wait-seconds))
  (let ((url-request-extra-headers '(("X-Fast-Or-Safe" . "fast")))
        (url-request-method "POST")
        (url-request-data contents)
        (url (format "http://%s:%s"
                     pretty-py-blackd-host
                     pretty-py-blackd-port)))
    (when pretty-py-black-fast-flag
      (push '("X-Fast-Or-Safe" . "fast") url-request-extra-headers))
    (when pretty-py-black-line-length
      (push `("X-Line-Length" . ,(number-to-string pretty-py-black-line-length))
            url-request-extra-headers))
    (message "Sending request to blackd at %s" url)
    (let ((buffer (url-retrieve-synchronously url
                                              'silent
                                              'inhibit-cookies
                                              pretty-py-blackd-request-timeout-seconds))
          status output)
      (with-current-buffer buffer
        (goto-char (point-min))
        (forward-word 4)
        (setq status (string-to-number (word-at-point)))
        (re-search-forward "^$")
        (setq output (buffer-substring (1+ (point)) (point-max))))

      (case status
        (204 'no-change)
        (200 (write-region output nil out-file)
             t)
        (t (with-current-buffer err-buf
             (insert output))
           (message "Blackd failed, HTTP status: %s" status)
           nil)))))

(defun pretty-py--via-program (inp-file err-buf)
  "Format INP-FILE with the chose format program. Errors appear in ERR-BUF."
  (let ((tool-name (symbol-name pretty-py-formatter)) tool-bin tool-args)
    (case pretty-py-formatter
      (yapf
       (setq
        tool-bin pretty-py-yapf-command
        tool-args (append pretty-py-yapf-args `("-i" ,inp-file))))
      (autopep8
       (setq
        tool-bin pretty-py-autopep8-command
        tool-args (append pretty-py-autopep8-args `("-i" ,inp-file))))
      (black
       (setq
        tool-bin pretty-py-black-command
        tool-args (append pretty-py-black-args
                          `("--quiet"
                            ,@(when pretty-py-black-fast-flag '("--fast"))
                            ,@(when pretty-py-black-line-length
                                (list (format "--line-length=%s"
                                              pretty-py-black-line-length)))
                            ,inp-file)))))

    (message "Calling %s: %s %s" tool-name tool-bin (string-join tool-args " "))
    ;; We're using err-buf for the mixed stdout and stderr output. This
    ;; is not an issue because yapf/black either produces an error or the diff
    (if (zerop (apply #'process-file tool-bin nil err-buf nil tool-args))
        t
      (message "Running %s failed" tool-name)
      nil)))

(defun pretty-py--before-save ()
  "Hook run from `before-save-hook'."
  (if pretty-py-mode
      (pretty-py-buffer)))

;;;###autoload
(define-minor-mode pretty-py-mode
  "Automatically run pretty-py-buffer before saving."
  :lighter "pretty-py"
  (if pretty-py-mode
      (add-hook 'before-save-hook #'pretty-py--before-save)))

(provide 'pretty-py)

;;; pretty-py.el ends here
