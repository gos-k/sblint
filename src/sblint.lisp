(in-package #:cl-user)
(defpackage #:sblint
  (:use #:cl)
  (:import-from #:sblint/file-location
                #:compiler-source-path
                #:compiler-note-position
                #:file-position-to-line-and-column)
  (:import-from #:sblint/logger
                #:*enable-logger*
                #:do-log)
  (:import-from #:sblint/error
                #:sblint-error
                #:sblint-compilation-error)
  (:import-from #:sblint/util
                #:with-muffled-streams
                #:make-relative-pathname
                #:condition-name-to-print
                #:install-required-systems
                #:all-required-systems
                #:directory-asd-files
                #:asdf-target-system-locator
                #:file-in-directory-p)
  (:import-from #:uiop
                #:file-exists-p
                #:directory-exists-p
                #:subdirectories
                #:directory-files)
  (:export #:run-lint-file
           #:run-lint-asd
           #:run-lint-directory
           #:sblint-error
           #:*enable-logger*))
(in-package #:sblint)

(defun run-lint-asd (asd-file &optional (stream *standard-output*))
  (do-log :info "Lint system ~A" (make-relative-pathname asd-file))

  (let ((file (probe-file asd-file)))
    (unless file
      (error "ASD file does not exist: '~A'" asd-file))

    (unless (equal (pathname-type file) "asd")
      (error "Not ASD file: '~A'" file))

    (asdf:load-asd file)
    (let* ((asdf:*system-definition-search-functions*
             (cons (asdf-target-system-locator (pathname-name file))
                   asdf:*system-definition-search-functions*))
           (system (with-muffled-streams
                     (asdf:find-system (pathname-name file) nil))))
      (unless system
        (error "System '~A' does not exist in '~A'."
               (pathname-name file)
               file))

      ;; Ensure dependencies are installed
      #+quicklisp
      (install-required-systems (pathname-name file))

      ;; Ensure dependencies are loaded
      (let ((dependencies #+quicklisp (all-required-systems (asdf:component-name system))
                          #-quicklisp (all-required-systems (asdf:component-name system))))
        (when dependencies
          (do-log :info "Loading ~D ~:*system~[s~;~:;s~]:~%  ~{~A~^ ~}"
            (length dependencies)
            dependencies)
          (handler-bind ((warning #'muffle-warning))
            #+quicklisp
            (ql:quickload dependencies :silent t)
            #-quicklisp
            (mapc (lambda (name)
                    (with-muffled-streams
                      (asdf:load-system name :verbose nil)))
                  dependencies))))

      (let ((directory (make-pathname :defaults file
                                      :name nil
                                      :type nil))
            (errout *error-output*))
        (labels ((ignore-and-continue (e)
                   (let ((accept (find-restart 'asdf/action:accept e)))
                     (when accept
                       (invoke-restart accept)))
                   (let ((continue (find-restart 'continue e)))
                     (when continue
                       (invoke-restart continue))))
                 (handle-compile-error (e)
                   (let ((*error-output* errout))
                     (if (remove-if-not (lambda (comp)
                                          (file-in-directory-p
                                           (asdf:component-pathname comp)
                                           directory))
                                        (mapcar #'cdr
                                                (uiop/lisp-build::compile-condition-context-arguments e)))
                         (warn "Compilation failed in a system ~S."
                               (asdf:component-name system))
                         (ignore-and-continue e)))))
          (run-lint-fn (lambda ()
                         (do-log :info "Loading a system: ~A" (asdf:component-name system))
                         (handler-bind ((asdf:compile-error #'handle-compile-error)
                                        #+asdf3
                                        (uiop:compile-file-error #'handle-compile-error)
                                        #+sbcl
                                        (sb-int:package-at-variance #'ignore-and-continue))
                           (with-muffled-streams
                             (asdf:load-system system)))
                         (do-log :info "Done"))
                       stream
                       *error-output*
                       directory))))

    (values)))

(defun run-lint-file (file &optional (stream *standard-output*))
  (do-log :info "Lint file ~A" (make-relative-pathname file))

  (unless (uiop:file-exists-p file)
    (error "File does not exist: '~A'" file))

  (when (equal (pathname-type file) "asd")
    (return-from run-lint-file
      (run-lint-asd file stream)))

  (let ((err (make-broadcast-stream)))
    (unless (run-lint-fn (lambda ()
                           (load file :verbose nil :print nil))
                         stream
                         err)
      (error 'sblint-compilation-error
             :file file
             :message (get-output-stream-string err)))))

(defun run-lint-fn (fn &optional (stream *standard-output*) (error *error-output*) directory)
  (let* ((errout *error-output*)
         (*error-output* error)
         (error-map (make-hash-table :test 'equalp)))
    (flet ((handle-condition (condition)
             (let* ((*error-output* errout)
                    (sb-int:*print-condition-references* nil)
                    (context (sb-c::find-error-context nil))
                    (file (or (and context
                                   (sb-c::compiler-error-context-file-name context))
                              *load-truename*
                              *compile-file-truename*))
                    (position (cond
                                ((and (typep file '(or string pathname))
                                      context)
                                 (compiler-note-position
                                  file
                                  (compiler-source-path context)))
                                ((typep condition 'reader-error)
                                 (let ((stream (stream-error-stream condition)))
                                   (file-position stream)))
                                (t nil))))
               (cond
                 ((and position
                       (or (not directory)
                           (and file
                                (file-in-directory-p file directory)
                                (not (file-in-directory-p file (merge-pathnames #P"quicklisp/" directory)))
                                (not (file-in-directory-p file (merge-pathnames #P".qlot/" directory)))))
                       (not (gethash (list file position (princ-to-string condition)) error-map)))
                  (setf (gethash (list file position (princ-to-string condition)) error-map) t)
                  (multiple-value-bind (line column)
                      (file-position-to-line-and-column file position)
                    (let ((*print-pretty* nil))
                      (handler-case
                          (format stream "~&~A:~A:~A: ~A: ~A~%"
                                  (make-relative-pathname file)
                                  line
                                  column
                                  (condition-name-to-print condition)
                                  condition)
                        (sb-int:simple-stream-error () (continue))))))
                 ((and (not (typep condition '(or #+asdf3.3 asdf/operate:recursive-operate
                                                  ;; XXX: Actual redefinition should be warned, however it loads the same file twice when compile-time & load-time and it shows many redefinition warnings.
                                                  sb-kernel:redefinition-warning
                                                  uiop:compile-warned-warning)))
                       (or (null file)
                           (let ((real-file
                                   (if (file-in-directory-p file asdf:*user-cache*)
                                       (let ((tmp
                                               (make-relative-pathname file asdf:*user-cache*)))
                                         (make-pathname :defaults file :directory (cons :absolute (cdr (pathname-directory tmp)))))
                                       file)))
                             (and (file-in-directory-p real-file directory)
                                  (not (file-in-directory-p real-file (merge-pathnames #P"quicklisp/" directory)))
                                  (not (file-in-directory-p real-file (merge-pathnames #P".qlot/" directory)))))))
                  (format *error-output*
                          "~&WARNING~@[ while loading '~A'~]:~% ~A~%"
                          file
                          condition))))))
      (handler-bind ((sb-c:fatal-compiler-error #'handle-condition)
                     (sb-c:compiler-error #'handle-condition)
                     ;; Ignore compiler-note for now.
                     ;; Perhaps those notes could be shown by some command-line option.
                     ;; (sb-ext:compiler-note #'handle-condition)
                     (error #'handle-condition)
                     (warning #'handle-condition))
        (funcall fn)))))

(defvar *global-enable-logger*)
(defun run-lint-directory (directory &optional (stream *standard-output*))
  (let ((*global-enable-logger*
          (if (boundp '*global-enable-logger*)
              *global-enable-logger*
              *enable-logger*)))
    (do-log :info "Lint directory '~A'" (make-relative-pathname directory))

    (unless (uiop:directory-exists-p directory)
      (error "Directory does not exist: '~A'" directory))

    (dolist (dir (uiop:subdirectories directory))
      (unless (or (equal (car (last (pathname-directory dir))) "quicklisp")
                  (equal (car (last (pathname-directory dir))) ".qlot"))
        (let ((*enable-logger* nil))
          (run-lint-directory dir stream))))
    (let ((asdf:*central-registry* (cons directory asdf:*central-registry*)))
      (let ((*enable-logger* *global-enable-logger*))
        (dolist (file (directory-asd-files directory))
          (run-lint-file file stream)))))

  (values))
