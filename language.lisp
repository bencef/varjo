;; This software is Copyright (c) 2012 Chris Bagley
;; (techsnuffle<at>gmail<dot>com)
;; Chris Bagley grants you the rights to
;; distribute and use this software as governed
;; by the terms of the Lisp Lesser GNU Public License
;; (http://opensource.franz.com/preamble.html),
;; known as the LLGPL.

(in-package :varjo)

;;------------------------------------------------------------
;; Built-in Structs
;;------------------

(%vdefstruct vgl-per-vertex-v (:slot-prefix per-vertex
                                            :context-restriction ((:330) :vertex))
  (position :vec4 "gl_Position")
  (point-size :float "gl_PointSize")
  (clip-distance (:float t) "gl_ClipDistance")
  (clip-vertex :vec4 "gl_ClipVertex"))

(%vdefstruct vgl-per-vertex-g (:slot-prefix per-vertex
                                            :context-restriction ((:330) :fragment))
  (position :vec4 "gl_Position")
  (point-size :float "gl_PointSize")
  (clip-distance (:float t) "gl_ClipDistance"))

;;------------------------------------------------------------
;; Special Functions
;;-------------------

(vdefspecial + (&rest args)    
  (let* ((arg-objs (mapcar #'varjo->glsl args))
         (types (mapcar #'code-type arg-objs)))
    (if (apply #'types-compatiblep types)
        (merge-obs arg-objs
                   :type (apply #'superior-type types)
                   :current-line (format nil "(~{~a~^ ~^+~^ ~})"
                                         (mapcar #'current-line 
                                                 arg-objs)))
        (error "The types of object passed to + are not compatible~%~{~s~^ ~}" types))))

(vdefspecial %- (&rest args)    
  (let* ((arg-objs (mapcar #'varjo->glsl args))
         (types (mapcar #'code-type arg-objs)))
    (if (apply #'types-compatiblep types)
        (merge-obs arg-objs
                   :type (apply #'superior-type types)
                   :current-line (format nil "(~{~a~^ ~^-~^ ~})"
                                         (mapcar #'current-line 
                                                 arg-objs)))
        (error "The types of object passed to - are not compatible~%~{~s~^ ~}" types))))

(vdefspecial / (&rest args)    
  (let* ((arg-objs (mapcar #'varjo->glsl args))
         (types (mapcar #'code-type arg-objs)))
    (if (apply #'types-compatiblep types)
        (merge-obs arg-objs
                   :type (apply #'superior-type types)
                   :current-line (format nil "(~{~a~^ ~^/~^ ~})"
                                         (mapcar #'current-line 
                                                 arg-objs)))
        (error "The types of object passed to / are not compatible~%~{~s~^ ~}" types))))

(vdefspecial ? (test-form then-form &optional else-form)
  (let* ((test (varjo->glsl test-form))
         (t-obj (varjo->glsl then-form))
         (nil-obj (varjo->glsl else-form))
         (arg-objs (remove-if #'null (list test t-obj nil-obj))))
    (if (glsl-typep test '(:bool nil))
        (if (equal (code-type nil-obj) (code-type t-obj))
            (merge-obs 
             arg-objs
             :type (code-type nil-obj)
             :current-line (format nil "(~a ? ~a : ~a)"
                                   (current-line test)
                                   (current-line t-obj)
                                   (current-line nil-obj)))
            (error "Verjo: Both potential outputs must be of the same type"))
        (error "The result of the test must be a bool.~%~a"
               (code-type test)))))


;; [TODO] double check implications of typify in compile-let-forms
(vdefspecial for (var-form condition update &rest body)
  "(for (a 0) (< a 10) (++ a)
     (* a 2))"
  (if 
   (consp (first var-form))
   (error "for can only iterate over one variable")
   (destructuring-bind (form-objs new-vars)
       (compile-let-forms (list var-form) t)
     (let* ((form-obj (first form-objs))
            (*glsl-variables* (append new-vars *glsl-variables*))
            (con-ob (varjo->glsl condition))
            (up-ob (varjo->glsl update))
            (prog-ob (end-line (indent-ob (apply-special 'progn body)))))
       (if (and (null (to-block con-ob)) (null (to-block up-ob)))
           
           (merge-obs (list prog-ob form-obj)
                      :type :none
                      :current-line nil
                      :to-block 
                      (list
                       (fmt "~{~a~%~}for (~a;~a;~a) {~%~{~a~%~}    ~a~%}"
                            (to-block form-obj)
                            (current-line form-obj)
                            (current-line con-ob)
                            (current-line up-ob)
                            (to-block prog-ob)
                            (current-line prog-ob))))
           (error "Varjo: Only simple expressions are allowed in the condition and update slots of a for loop"))))))

(vdefspecial if (test-form then-form &optional else-form)  
  (let* ((test (varjo->glsl test-form))
         (t-obj (end-line (indent-ob (varjo->glsl then-form))))
         (nil-obj (when else-form (end-line (indent-ob (varjo->glsl else-form)))))
         (arg-objs (remove-if #'null (list test t-obj nil-obj))))
    (if (glsl-typep test '(:bool nil))
        (merge-obs 
         arg-objs
         :type :none
         :current-line nil
         :to-block 
         (list (if nil-obj
                   (format nil "~a~&if (~a) {~{~%~a~}~%    ~a~%} else {~{~%~a~}~%    ~a~%}"
                           (or (to-block test) "") 
                           (current-line test)
                           (or (to-block t-obj) nil) 
                           (current-line t-obj)
                           (or (to-block nil-obj) nil) 
                           (current-line nil-obj))
                   (format nil "~a~&if (~a) {~{~%~a~}~%    ~a~%}"
                           (or (to-block test) "") 
                           (current-line test)
                           (or (to-block t-obj) nil)
                           (current-line t-obj)))))
        (error "The result of the test must be a bool.~%~s"
               (code-type test)))))

(vdefspecial %init-vec-or-mat (type &rest args)
  (labels ((type-size (arg-type) 
             (let ((arg-type (type-principle arg-type)))
               (if (type-aggregate-p arg-type)
                   (type-component-count arg-type)
                   (if (eq arg-type (type-component-type type))
                       1
                       (error "Varjo: ~a is not of suitable type to be a component of ~a" 
                              arg-type type))))))
    (let* ((target-type (flesh-out-type type))
           (target-length (type-component-count target-type))
           (arg-objs (mapcar #'varjo->glsl args))
           (types (mapcar #'code-type arg-objs))
           (lengths (mapcar #'type-size types)))
      (if (eq target-length (apply #'+ lengths))
          (merge-obs arg-objs
                     :type target-type
                     :current-line 
                     (format nil "~a(~{~a~^,~^ ~})"
                             (varjo-type->glsl-type target-type)
                             (mapcar #'current-line arg-objs)))
          (error "The lengths of the types provided~%(~{~a~^,~^ ~})~%do not add up to the length of ~a" types target-type)))))

;; [TODO] Pretty sure this has a bug where if you use an in-built
;;        type with upper and lower case, this will just write 
;;        lower-case
(vdefspecial labels (func-specs &rest body)
  (let ((func-objs) (processed nil) (todo func-specs) (count 0))
    (loop :until (or (not todo) (>= count (length todo))) :do
       (let* ((*glsl-functions* (acons-many processed *glsl-functions*))
              (spec (first todo))
              (obj (handler-case (varjo->glsl (cons '%make-function spec))
                     (missing-function-error ()
                       (progn (setf todo `(,@(rest todo) ,(first todo)))
                              (incf count)
                              nil)))))
         (when obj
           (setf count 0)
           (push obj func-objs)
           (pop todo)
           (push (list (first spec) 
                       (vlambda :in-args (second spec)
                                :output-type (code-type obj)
                                :transform 
                                (format nil "~a(~{~a~^,~^ ~})"
                                        (safe-gl-name '-f (first spec))
                                        (loop for i below (length (second spec))
                                           :collect "~a"))))
                 processed))))
    (if todo
        (error "Functions unresolvable in labels block~{~%~s~}" todo)
        (let ((*glsl-functions* (acons-many processed *glsl-functions*)))
          (let ((prog-obj (apply-special 'progn body)))
            (merge-obs (append func-objs (list prog-obj))
                       :type (code-type prog-obj)
                       :current-line (current-line prog-obj)))))))

(vdefspecial let (form-code &rest body-code)
  ;; check for name clashes between forms
  ;; create init forms, for each one 
  (destructuring-bind (form-objs new-vars)
      (compile-let-forms form-code)
    (let* ((*glsl-variables* (append new-vars *glsl-variables*))
           (prog-ob (apply-special 'progn body-code)))
      (merge-obs (cons prog-ob form-objs)
                 :type (code-type prog-ob)
                 :current-line (current-line prog-ob)
                 :to-block (append 
                            (mapcan #'to-block form-objs)
                            (mapcar (lambda (x) 
                                      (current-line (end-line x)))
                                    form-objs)
                            (to-block prog-ob))
                 :to-top (append (mapcan #'to-top form-objs)
                                 (to-top prog-ob))))))

(vdefspecial %make-array (type length &optional contents)
  (let* ((literal-length (typep length 'code))
         (length (varjo->glsl length))
         (contents (mapcar #'varjo->glsl contents)))
    (merge-obs 
     (cons length contents)
     :type (flesh-out-type 
            `(,type ,(if literal-length
                         (parse-integer (current-line length))
                         t)))
     :current-line (format nil "~a[~a]{~{~a~^,~}}" 
                           type
                           (current-line length) 
                           (mapcar #'current-line contents)))))

;;[TODO] arg names arent always safe (try anything with a hyphon)
(vdefspecial %make-function (name args &rest body)
  (let ((name (if (eq name :main) :main (symb '-f name))))
    (destructuring-bind (form-objs new-vars)
        (compile-let-forms (mapcar #'list args) nil nil)
      (declare (ignore form-objs))
      (let* ((*glsl-variables* (append new-vars *glsl-variables*)) 
             (body-obj (indent-ob (apply-special 'progn body)))
             (name (if (eq name :main) :main name))
             (returns (returns body-obj))
             (type (if (eq name :main) '(:void nil nil) 
                       (first returns))))
        (let ((name (safe-gl-name name)))
          (if (or (not returns) (loop for r in returns always (equal r (first returns))))
              (make-instance 
               'code :type type
               :current-line nil
               :to-top (append 
                        (to-top body-obj)
                        (list (format 
                               nil "~a ~a(~(~{~{~a ~a~}~^,~^ ~}~)) {~%~{~a~%~}~@[    ~a~%~]}~%"
                               (varjo-type->glsl-type type)
                               name 
                               (mapcar #'reverse args)
                               (to-block body-obj) 
                               (current-line (end-line body-obj)))))

               :out-vars (out-vars body-obj))
              (error "Some of the return statements in function '~a' return different types~%~a~%~a" name type returns)))))))

(vdefspecial %make-var (name type)
  (make-instance 'code :type (set-place-t type)
                 :current-line (string name)))

(vdefspecial %negate (form)  
  (let* ((arg-obj (varjo->glsl form)))
    (merge-obs arg-obj
               :current-line (format nil "-~a"
                                     (current-line arg-obj)))))

(vdefspecial out (name-and-qualifiers form)
  (let ((arg-obj (varjo->glsl form))
        (out-var-name (if (consp name-and-qualifiers)
                          (first name-and-qualifiers)
                          name-and-qualifiers))
        (qualifiers (when (consp name-and-qualifiers)
                      (rest name-and-qualifiers))))
    (if (assoc out-var-name *glsl-variables*)
        (error "The variable name '~a' is already taken and so cannot be used~%for an out variable" out-var-name)
        (make-instance 'code
                       :type :void
                       :current-line (fmt "~a = ~a;" 
                                          (safe-gl-name out-var-name)
                                          (current-line arg-obj))
                       :to-block (to-block arg-obj)
                       :out-vars `((,out-var-name
                                    ,(code-type arg-obj)
                                    ,(safe-gl-name out-var-name) 
                                    ,@qualifiers))))))

(vdefspecial progn (&rest body)
  (let ((arg-objs (mapcar #'varjo->glsl body)))
    (cond 
      ((eq 0 (length arg-objs)) (make-none-ob))
      ((eq 1 (length arg-objs))
       (let ((ob (first arg-objs)))
         (merge-obs ob :current-line (current-line ob))))
      (t (let ((last-arg (car (last arg-objs)))
               (args (subseq arg-objs 0 (- (length arg-objs) 1))))
           (merge-obs arg-objs
                      :type (code-type last-arg)
                      :current-line (current-line last-arg)
                      :to-block 
                      (remove #'null
                              (append (loop for i in args
                                         for j in (mapcar #'end-line args)
                                         append (to-block i) 
                                         collect (current-line j))
                                      (to-block last-arg)))))))))

;; [TODO] why does this need semicolon?
(vdefspecial return (&optional (form '(%void)))
  (let ((ob (varjo->glsl form)))
    (if (eq :none (code-type ob))
        ob
        (merge-obs ob
                   :current-line (format nil "return ~a;" 
                                         (current-line ob))
                   :type :none
                   :returns (list (code-type ob))))))

(vdefspecial switch (test-form &rest clauses)    
  (let* ((test (varjo->glsl test-form))
         (keys (mapcar #'first clauses))
         (arg-objs (mapcar #'(lambda (x) (varjo->glsl (second x)))
                           clauses))
         (format-clauses 
          (loop :for key :in keys
             :for obj :in arg-objs
             :append
             (cond ((eq key 'otherwise) 
                    (list "default" nil "jam"))
                   ((glsl-typep key '(:int nil))
                    (list (current-line key)
                          (or (to-block obj) nil) 
                          (current-line obj)))))))
    (if (glsl-typep test '(:int nil))
        (merge-obs 
         arg-objs
         :type :none
         :current-line ""
         :to-block 
         (list 
          (format nil "~a~%switch (~a) {~{~%case ~a:~%~{~a~^~%~}~a;~%break;~}}"
                  (or (to-block test) "") 
                  (current-line test)
                  format-clauses)))
        (error "The result of the test must be an int.~%~s"
               (code-type test)))))

(vdefspecial %%typify (form)
  (let* ((arg (varjo->glsl form))
         (type (code-type arg)))
    (merge-obs arg :current-line 
               (format nil "<~a ~a>" type (current-line arg)))))

(vdefspecial %typify (form)
  (let* ((arg (varjo->glsl form))
         (type (code-type arg)))
    (merge-obs arg :current-line 
               (format nil "~a ~a" (varjo-type->glsl-type type)
                       (current-line arg)))))

(vdefspecial %in-typify (form &optional (qualifiers nil))
  (let* ((arg (varjo->glsl form))
         (type (code-type arg)))
    (merge-obs arg :current-line 
               (format nil "~a ~{~a ~}~a~@[[~a]~]" 
                       (varjo-type->glsl-type type)
                       qualifiers
                       (current-line arg)
                       (when (second type)
                         (if (numberp (second type))
                             (second type)
                             ""))))))

(vdefspecial while (test &rest body)
  (let* ((test-ob (varjo->glsl test))
         (prog-ob (end-line (apply-special 'progn body))))
    (merge-obs (list prog-ob test-ob)
               :type :none
               :current-line nil
               :to-block 
               (list
                (format nil "~{~a~%~}while (~a) {~%~{~a~%~}~a;~%}"
                        (to-block test-ob)
                        (current-line test-ob)
                        (to-block prog-ob)
                        (current-line prog-ob))))))

(vdefspecial swizzle (vec-form components)
  (let* ((vec-ob (varjo->glsl vec-form))
         (vec-type (code-type vec-ob)))
    (if (type-vec-core-type vec-type)
        (let* ((comp (string-downcase (string (if (listp components)
                                                  (cadr components)
                                                  components))))
               (len (length comp)))
          (if (<= len 4)
              (merge-obs (list vec-ob)	
                         :type (set-place-t (change-vec-length
                                             vec-type len))
                         :current-line (format nil "~a.~a"
                                               (current-line vec-ob)
                                               comp))
              (error "Varjo: Invlaid length of components for swizzle")))
        (error "Varjo: Trying to swizzle a non vector: ~a" vec-type))))

;;------------------------------------------------------------
;; Core Language Definitions
;;---------------------------

(glsl-defun :name '%void
            :in-args '()
            :output-type :void
            :transform ""
            :context-restriction nil)

(glsl-defun :name 'x
            :in-args '((vec ((:bvec2 :bvec3 :bvec4))))
            :output-type :bool
            :transform "~a.x"
            :context-restriction '((:330)))

(glsl-defun :name 'x
            :in-args '((vec ((:ivec2 :ivec3 :ivec4))))
            :output-type :int
            :transform "~a.x"
            :context-restriction '((:330)))

(glsl-defun :name 'x
            :in-args '((vec ((:uvec2 :uvec3 :uvec4))))
            :output-type :uint
            :transform "~a.x"
            :context-restriction '((:330)))

(glsl-defun :name 'x
            :in-args '((vec ((:vec2 :vec3 :vec4))))
            :output-type :float
            :transform "~a.x"
            :context-restriction '((:330)))

(glsl-defun :name 'y
            :in-args '((vec ((:bvec2 :bvec3 :bvec4))))
            :output-type :bool
            :transform "~a.y"
            :context-restriction '((:330)))

(glsl-defun :name 'y
            :in-args '((vec ((:ivec2 :ivec3 :ivec4))))
            :output-type :int
            :transform "~a.y"
            :context-restriction '((:330)))

(glsl-defun :name 'y
            :in-args '((vec ((:uvec2 :uvec3 :uvec4))))
            :output-type :uint
            :transform "~a.y"
            :context-restriction '((:330)))

(glsl-defun :name 'y
            :in-args '((vec ((:vec2 :vec3 :vec4))))
            :output-type :float
            :transform "~a.y"
            :context-restriction '((:330)))

(glsl-defun :name 'z
            :in-args '((vec ((:bvec3 :bvec4))))
            :output-type :bool
            :transform "~a.z"
            :context-restriction '((:330)))

(glsl-defun :name 'z
            :in-args '((vec ((:ivec3 :ivec4))))
            :output-type :int
            :transform "~a.z"
            :context-restriction '((:330)))

(glsl-defun :name 'z
            :in-args '((vec ((:uvec3 :uvec4))))
            :output-type :uint
            :transform "~a.z"
            :context-restriction '((:330)))

(glsl-defun :name 'z
            :in-args '((vec ((:vec3 :vec4))))
            :output-type :float
            :transform "~a.z"
            :context-restriction '((:330)))

(glsl-defun :name 'w
            :in-args '((vec :bvec4))
            :output-type :bool
            :transform "~a.w"
            :context-restriction '((:330)))

(glsl-defun :name 'w
            :in-args '((vec :ivec4))
            :output-type :int
            :transform "~a.w"
            :context-restriction '((:330)))

(glsl-defun :name 'w
            :in-args '((vec :uvec4))
            :output-type :uint
            :transform "~a.w"
            :context-restriction '((:330)))

(glsl-defun :name 'w
            :in-args '((vec :vec4))
            :output-type :float
            :transform "~a.w"
            :context-restriction '((:330)))

(glsl-defun :name 'bool
            :in-args '((x ((:double :float :int :uint :bool
                                    :bvec2 :bvec3 :bvec4))))
            :output-type :bool
            :transform "bool(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'double
            :in-args '((x ((:bool :float :int :uint :double))))
            :output-type :double
            :transform "double(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'float
            :in-args '((x ((:bool :double :int :uint :float
                                  :vec2 :vec3 :vec4))))
            :output-type :float
            :transform "float(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'int
            :in-args '((x ((:bool :double :float :uint :int
                                  :ivec2 :ivec3 :ivec4))))
            :output-type :int
            :transform "int(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'uint
            :in-args '((x ((:bool :double :float :int :uint
                                  :uvec2 :uvec3 :uvec4))))
            :output-type :uint
            :transform "uint(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'uint
            :in-args '((x ((:bool :double :float :int :uint
                                  :uvec2 :uvec3 :uvec4))))
            :output-type :uint
            :transform "uint(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'degrees
            :in-args '((radians ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "degrees(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'radians
            :in-args '((degrees ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "radians(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'sin
            :in-args '((angle ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "sin(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'cos
            :in-args '((angle ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "cos(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'tan
            :in-args '((angle ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "tan(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'asin
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "asin(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'acos
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "acos(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'atan
            :in-args '((y ((:float :vec2 :vec3 :vec4)) :compatible)
                       (x ((:float :vec2 :vec3 :vec4)) :compatible))
            :output-type '(0 nil)
            :transform "atan(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'atan
            :in-args '((y-over-x ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "atan(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'sinh
            :in-args '((angle ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "sinh(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'cosh
            :in-args '((angle ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "cosh(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'tanh
            :in-args '((angle ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "tanh(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'asinh
            :in-args '((angle ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "asinh(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'acosh
            :in-args '((angle ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "acosh(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'atanh
            :in-args '((angle ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "atanh(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'pow
            :in-args '((x ((:float :vec2 :vec3 :vec4)))
                       (y ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "pow(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'exp
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "exp(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'log
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "log(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'exp2
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "exp2(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'log2
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "log2(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'sqrt
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "exp(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'inversesqrt
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "inversesqrt(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'abs
            :in-args '((x ((:float :vec2 :vec3 :vec4
                                   :int :ivec2 :ivec3 :ivec4))))
            :output-type '(0 nil)
            :transform "abs(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'sign
            :in-args '((x ((:float :vec2 :vec3 :vec4
                                   :int :ivec2 :ivec3 :ivec4))))
            :output-type '(:float nil)
            :transform "sign(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'floor
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(:int nil)
            :transform "floor(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'trunc
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(:int nil)
            :transform "trunc(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'round
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(:int nil)
            :transform "round(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'round-even
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(:int nil)
            :transform "roundEven(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'ceil
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(:int nil)
            :transform "ceil(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'fract
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "fract(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'mod
            :in-args '((x ((:float :vec2 :vec3 :vec4)))
                       (y ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "mod(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'min
            :in-args '((x ((:float :vec2 :vec3 :vec4
                                   :int :ivec2 :ivec3 :ivec4
                                   :uint :uvec2 :uvec3 :uvec4)) :match)
                       (y ((:float :vec2 :vec3 :vec4
                                   :int :ivec2 :ivec3 :ivec4
                                   :uint :uvec2 :uvec3 :uvec4)) :match))
            :output-type '(0 nil)
            :transform "min(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'min
            :in-args '((x ((:float :vec2 :vec3 :vec4)))
                       (y :float))
            :output-type '(0 nil)
            :transform "min(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'min
            :in-args '((x ((:int :ivec2 :ivec3 :ivec4)))
                       (y :int))
            :output-type '(0 nil)
            :transform "min(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'min
            :in-args '((x ((:uint :uvec2 :uvec3 :uvec4)))
                       (y :uint))
            :output-type '(0 nil)
            :transform "min(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'max
            :in-args '((x ((:float :vec2 :vec3 :vec4
                                   :int :ivec2 :ivec3 :ivec4
                                   :uint :uvec2 :uvec3 :uvec4)) :match)
                       (y ((:float :vec2 :vec3 :vec4
                                   :int :ivec2 :ivec3 :ivec4
                                   :uint :uvec2 :uvec3 :uvec4)) :match))
            :output-type '(0 nil)
            :transform "max(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'max
            :in-args '((x ((:float :vec2 :vec3 :vec4)))
                       (y :float))
            :output-type '(0 nil)
            :transform "max(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'max
            :in-args '((x ((:int :ivec2 :ivec3 :ivec4)))
                       (y :int))
            :output-type '(0 nil)
            :transform "max(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'max
            :in-args '((x ((:uint :uvec2 :uvec3 :uvec4)))
                       (y :uint))
            :output-type '(0 nil)
            :transform "max(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'clamp
            :in-args '((x ((:float :vec2 :vec3 :vec4
                                   :int :ivec2 :ivec3 :ivec4
                                   :uint :uvec2 :uvec3 :uvec4)) :match)
                       (min-val ((:float :vec2 :vec3 :vec4
                                         :int :ivec2 :ivec3 :ivec4
                                         :uint :uvec2 :uvec3 :uvec4)) 
                        :match)
                       (max-val ((:float :vec2 :vec3 :vec4
                                         :int :ivec2 :ivec3 :ivec4
                                         :uint :uvec2 :uvec3 :uvec4))
                        :match))
            :output-type '(0 nil)
            :transform "clamp(~a, ~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'clamp
            :in-args '((x ((:float :vec2 :vec3 :vec4)) )
                       (min-val :float )
                       (max-val :float ))
            :output-type '(0 nil)
            :transform "clamp(~a, ~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'clamp
            :in-args '((x ((:int :ivec2 :ivec3 :ivec4)) )
                       (min-val :int )
                       (max-val :int ))
            :output-type '(0 nil)
            :transform "clamp(~a, ~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'clamp
            :in-args '((x ((:uint :uvec2 :uvec3 :uvec4)))
                       (min-val :uint )
                       (max-val :uint ))
            :output-type '(0 nil)
            :transform "clamp(~a, ~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'mix
            :in-args '((x ((:float :vec2 :vec3 :vec4)) :match)
                       (y ((:float :vec2 :vec3 :vec4)) :match)
                       (a ((:float :vec2 :vec3 :vec4)) :match))
            :output-type '(0 nil)
            :transform "mix(~a, ~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'mix
            :in-args '((x ((:float :vec2 :vec3 :vec4)))
                       (y ((:float :vec2 :vec3 :vec4)))
                       (a ((:float :bvec2 :bvec3 :bvec4 :bool))))
            :output-type '(0 nil)
            :transform "mix(~a, ~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'smooth-step
            :in-args '((edge0 ((:float :vec2 :vec3 :vec4)) :match)
                       (edge1 ((:float :vec2 :vec3 :vec4)) :match)
                       (x ((:float :vec2 :vec3 :vec4)) :match))
            :output-type '(2 nil)
            :transform "smoothstep(~a, ~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'smooth-step
            :in-args '((edge0 :float)
                       (edge1 :float)
                       (x ((:float :vec2 :vec3 :vec4))))
            :output-type '(2 nil)
            :transform "smoothstep(~a, ~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'is-nan
            :in-args '((x :float))
            :output-type '(:bool nil)
            :transform "isnan(~a, ~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'is-nan
            :in-args '((x :vec2))
            :output-type '(:bvec2 nil)
            :transform "isnan(~a, ~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'is-nan
            :in-args '((x :vec3))
            :output-type '(:bvec3 nil)
            :transform "isnan(~a, ~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'is-nan
            :in-args '((x :vec4))
            :output-type '(:bvec4 nil)
            :transform "isnan(~a, ~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'length
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type :float
            :transform "length(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'distance
            :in-args '((p0 ((:float :vec2 :vec3 :vec4)) :match)
                       (p1 ((:float :vec2 :vec3 :vec4)) :match))
            :output-type :float
            :transform "distance(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'dot
            :in-args '((x ((:float :vec2 :vec3 :vec4)) :match)
                       (y ((:float :vec2 :vec3 :vec4)) :match))
            :output-type :float
            :transform "dot(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'cross
            :in-args '((x :vec3)
                       (y :vec3))
            :output-type :vec3
            :transform "cross(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'normalize
            :in-args '((x ((:float :vec2 :vec3 :vec4))))
            :output-type '(0 nil)
            :transform "normalize(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'aref
            :in-args '((array (t t))
                       (index ((:uint :int))))
            :output-type '(0 nil t)
            :transform "~a[~a]"
            :context-restriction '((:330)))

(glsl-defun :name 'aref
            :in-args '((vector ((:vec2 :vec3 :vec4)))
                       (index ((:uint :int))))
            :output-type '(:float 0 t)
            :transform "~a[~a]"
            :context-restriction '((:330)))

(glsl-defun :name 'aref
            :in-args '((vector ((:ivec2 :ivec3 :ivec4)))
                       (index ((:uint :int))))
            :output-type '(:int 0 t)
            :transform "~a[~a]"
            :context-restriction '((:330)))

(glsl-defun :name 'aref
            :in-args '((vector ((:uvec2 :uvec3 :uvec4)))
                       (index ((:uint :int))))
            :output-type '(:uint 0 t)
            :transform "~a[~a]"
            :context-restriction '((:330)))

(glsl-defun :name 'setf
            :in-args '((x (t nil t) :match)
                       (y (t nil nil) :match))
            :output-type '(0 0)
            :transform "~a = ~a"
            :context-restriction '((:330)))

(glsl-defun :name 'setf
            :in-args '((x (t t t) :match)
                       (y (t t nil) :match))
            :output-type '(0 0)
            :transform "~a = ~a"
            :context-restriction '((:330)))

(glsl-defun :name 'f-transform
            :in-args '()
            :output-type :vec4
            :transform "ftransform()"
            :context-restriction '((:330)))

(glsl-defun :name 'face-forward
            :in-args '((n ((:float :vec2 :vec3 :vec4)) :match)
                       (i ((:float :vec2 :vec3 :vec4)) :match)
                       (nref ((:float :vec2 :vec3 :vec4)) :match))
            :output-type '(0 0)
            :transform "faceforward(~a, ~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'reflect
            :in-args '((i ((:float :vec2 :vec3 :vec4)) :match)
                       (n ((:float :vec2 :vec3 :vec4)) :match))
            :output-type '(0 0)
            :transform "reflect(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'refract
            :in-args '((i ((:float :vec2 :vec3 :vec4)) :match)
                       (n ((:float :vec2 :vec3 :vec4)) :match)
                       (eta :float))
            :output-type '(0 0)
            :transform "reflect(~a, ~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'matrix-comp-mult
            :in-args '((i ((:mat2 :mat3 :mat4 
                                  :mat2x2 :mat2x3 :mat2x4 
                                  :mat3x2 :mat3x3 :mat3x4 
                                  :mat4x2 :mat4x3 :mat4x4)) :compatible)
                       (n ((:mat2 :mat3 :mat4 
                                  :mat2x2 :mat2x3 :mat2x4 
                                  :mat3x2 :mat3x3 :mat3x4 
                                  :mat4x2 :mat4x3 :mat4x4)) :compatible)
                       (eta :float))
            :output-type '(0 0)
            :transform "matrixCompMult(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'outer-product
            :in-args '((i :vec2)
                       (n :vec2))
            :output-type :mat2
            :transform "outerProduct(~a, ~a)")
(glsl-defun :name 'outer-product
            :in-args '((i :vec3)
                       (n :vec3))
            :output-type :mat3
            :transform "outerProduct(~a, ~a)")
(glsl-defun :name 'outer-product
            :in-args '((i :vec4)
                       (n :vec4))
            :output-type :mat4
            :transform "outerProduct(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'outer-product
            :in-args '((m :vec2)
                       (n :vec3))
            :output-type :mat3x2
            :transform "outerProduct(~a, ~a)")
(glsl-defun :name 'outer-product
            :in-args '((m :vec2)
                       (n :vec4))
            :output-type :mat4x2
            :transform "outerProduct(~a, ~a)")
(glsl-defun :name 'outer-product
            :in-args '((m :vec3)
                       (n :vec2))
            :output-type :mat2x3
            :transform "outerProduct(~a, ~a)")
(glsl-defun :name 'outer-product
            :in-args '((m :vec3)
                       (n :vec4))
            :output-type :mat4x3
            :transform "outerProduct(~a, ~a)")
(glsl-defun :name 'outer-product
            :in-args '((m :vec4)
                       (n :vec2))
            :output-type :mat2x4
            :transform "outerProduct(~a, ~a)")
(glsl-defun :name 'outer-product
            :in-args '((m :vec4)
                       (n :vec3))
            :output-type :mat4x3
            :transform "outerProduct(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'transpose
            :in-args '((m ((:mat2 :mat3 :mat4
                                  :mat2x2 :mat3x3 :mat4x4))))
            :output-type 0
            :transform "transpose(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'transpose
            :in-args '((m ((:mat2x3))))
            :output-type :mat3x2
            :transform "transpose(~a)")
(glsl-defun :name 'transpose
            :in-args '((m ((:mat2x4))))
            :output-type :mat4x2
            :transform "transpose(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'transpose
            :in-args '((m ((:mat3x2))))
            :output-type :mat2x3 
            :transform "transpose(~a)")
(glsl-defun :name 'transpose
            :in-args '((m ((:mat3x4))))
            :output-type :mat4x3
            :transform "transpose(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'transpose
            :in-args '((m ((:mat4x3))))
            :output-type :mat3x4 
            :transform "transpose(~a)")
(glsl-defun :name 'transpose
            :in-args '((m ((:mat4x2))))
            :output-type :mat2x4 
            :transform "transpose(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'determinant
            :in-args '((m ((:mat2 :mat3 :mat4 
                                  :mat2x2 :mat2x3 :mat2x4 
                                  :mat3x2 :mat3x3 :mat3x4 
                                  :mat4x2 :mat4x3 :mat4x4))))
            :output-type :float
            :transform "determinant(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'inverse
            :in-args '((m ((:mat2 :mat3 :mat4))))
            :output-type 0
            :transform "inverse(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'less-than
            :in-args '((x ((:vec2 :ivec2 :uvec2)) :compatible)
                       (y ((:vec2 :ivec2 :uvec2)) :compatible))
            :output-type :bvec2
            :transform "lessThan(~a, ~a)")
(glsl-defun :name 'less-than
            :in-args '((x ((:vec3 :ivec3 :uvec3)) :compatible)
                       (y ((:vec3 :ivec3 :uvec3)) :compatible))
            :output-type :bvec3
            :transform "lessThan(~a, ~a)")
(glsl-defun :name 'less-than
            :in-args '((x ((:vec4 :ivec4 :uvec4)) :compatible)
                       (y ((:vec4 :ivec4 :uvec4)) :compatible))
            :output-type :bvec4
            :transform "lessThan(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'less-than-equal
            :in-args '((x ((:vec2 :ivec2 :uvec2)) :compatible)
                       (y ((:vec2 :ivec2 :uvec2)) :compatible))
            :output-type :bvec2
            :transform "lessThanEqual(~a, ~a)")
(glsl-defun :name 'less-than-equal
            :in-args '((x ((:vec3 :ivec3 :uvec3)) :compatible)
                       (y ((:vec3 :ivec3 :uvec3)) :compatible))
            :output-type :bvec3
            :transform "lessThanEqual(~a, ~a)")
(glsl-defun :name 'less-than-equal
            :in-args '((x ((:vec4 :ivec4 :uvec4)) :compatible)
                       (y ((:vec4 :ivec4 :uvec4)) :compatible))
            :output-type :bvec4
            :transform "lessThanEqual(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'greater-than
            :in-args '((x ((:vec2 :ivec2 :uvec2)) :compatible)
                       (y ((:vec2 :ivec2 :uvec2)) :compatible))
            :output-type :bvec2
            :transform "greaterThan(~a, ~a)")
(glsl-defun :name 'greater-than
            :in-args '((x ((:vec3 :ivec3 :uvec3)) :compatible)
                       (y ((:vec3 :ivec3 :uvec3)) :compatible))
            :output-type :bvec3
            :transform "greaterThan(~a, ~a)")
(glsl-defun :name 'greater-than
            :in-args '((x ((:vec4 :ivec4 :uvec4)) :compatible)
                       (y ((:vec4 :ivec4 :uvec4)) :compatible))
            :output-type :bvec4
            :transform "greaterThan(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'greater-than-equal
            :in-args '((x ((:vec2 :ivec2 :uvec2)) :compatible)
                       (y ((:vec2 :ivec2 :uvec2)) :compatible))
            :output-type :bvec2
            :transform "greaterThanEqual(~a, ~a)")
(glsl-defun :name 'greater-than-equal
            :in-args '((x ((:vec3 :ivec3 :uvec3)) :compatible)
                       (y ((:vec3 :ivec3 :uvec3)) :compatible))
            :output-type :bvec3
            :transform "greaterThanEqual(~a, ~a)")
(glsl-defun :name 'greater-than-equal
            :in-args '((x ((:vec4 :ivec4 :uvec4)) :compatible)
                       (y ((:vec4 :ivec4 :uvec4)) :compatible))
            :output-type :bvec4
            :transform "greaterThanEqual(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'equal
            :in-args '((x ((:vec2 :ivec2 :uvec2)) :compatible)
                       (y ((:vec2 :ivec2 :uvec2)) :compatible))
            :output-type :bvec2
            :transform "equal(~a, ~a)")
(glsl-defun :name 'equal
            :in-args '((x ((:vec3 :ivec3 :uvec3)) :compatible)
                       (y ((:vec3 :ivec3 :uvec3)) :compatible))
            :output-type :bvec3
            :transform "equal(~a, ~a)")
(glsl-defun :name 'equal
            :in-args '((x ((:vec4 :ivec4 :uvec4)) :compatible)
                       (y ((:vec4 :ivec4 :uvec4)) :compatible))
            :output-type :bvec4
            :transform "equal(~a, ~a)")
(glsl-defun :name 'equal
            :in-args '((x ((:bvec2 :bvec3 :bvec4)) :match)
                       (y ((:bvec2 :bvec3 :bvec4)) :match))
            :output-type 0
            :transform "equal(~a, ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'b-any
            :in-args '((x ((:bvec2 :bvec3 :bvec4))))
            :output-type :bool
            :transform "any(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'b-all
            :in-args '((x ((:bvec2 :bvec3 :bvec4))))
            :output-type :bool
            :transform "all(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'b-not
            :in-args '((x ((:bvec2 :bvec3 :bvec4))))
            :output-type 0
            :transform "not(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'dfdx
            :in-args '((i ((:float :vec2 :vec3 :vec4))))
            :output-type 0
            :transform "dFdx(~a)"
            :context-restriction '(:fragment))

(glsl-defun :name 'dfdy
            :in-args '((i ((:float :vec2 :vec3 :vec4))))
            :output-type 0
            :transform "dFdy(~a)"
            :context-restriction '(:fragment))

(glsl-defun :name 'f-width
            :in-args '((i ((:float :vec2 :vec3 :vec4))))
            :output-type 0
            :transform "fwidth(~a)"
            :context-restriction '(:fragment))

(glsl-defun :name 'noise-1
            :in-args '((i ((:float :vec2 :vec3 :vec4))))
            :output-type :float
            :transform "noise1(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'noise-2
            :in-args '((i ((:float :vec2 :vec3 :vec4))))
            :output-type :vec2
            :transform "noise2(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'noise-3
            :in-args '((i ((:float :vec2 :vec3 :vec4))))
            :output-type :vec2
            :transform "noise3(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'noise-4
            :in-args '((i ((:float :vec2 :vec3 :vec4))))
            :output-type :vec2
            :transform "noise4(~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'emit-vertex
            :in-args nil
            :output-type :void
            :transform "EmitVertex()"
            :context-restriction '(:geometry))

(glsl-defun :name 'end-primitive
            :in-args nil
            :output-type :void
            :transform "EndPrimitive()"
            :context-restriction '(:geometry))

(glsl-defun :name 'discard
            :in-args '()
            :output-type :none
            :transform "discard()"
            :context-restriction '(:fragment))

;; [TODO] why does this need semicolon?
(glsl-defun :name 'break
            :in-args '()
            :output-type :none
            :transform "break;"
            :context-restriction '((:330)))

(glsl-defun :name 'continue
            :in-args '()
            :output-type :none
            :transform "continue"
            :context-restriction '((:330)))

(glsl-defun :name 'incf
            :in-args '((x ((:int :uint :float) nil nil)))
            :output-type 0
            :transform "(~a++)"
            :context-restriction '((:330)))

(glsl-defun :name 'decf
            :in-args '((x ((:int :uint :float) nil nil)))
            :output-type 0
            :transform "(~a--)"
            :context-restriction '((:330)))

(glsl-defun :name '++
            :in-args '((x ((:int :uint :float) nil nil)))
            :output-type 0
            :transform "(++~a)"
            :context-restriction '((:330)))

(glsl-defun :name '--
            :in-args '((x ((:int :uint :float) nil nil)))
            :output-type 0
            :transform "(--~a)"
            :context-restriction '((:330)))

(glsl-defun :name '*
            :in-args '((x ((:int :float)) :compatible)
                       (y ((:int :float)) :compatible))
            :output-type '(0 nil)
            :transform "(~a * ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '*
            :in-args '((x ((:int :float)))
                       (y ((:vec2 :vec3 :vec4
                                  :ivec2 :ivec3 :ivec4
                                  :mat2 :mat3 :mat4 
                                  :mat2x2 :mat2x3 :mat2x4
                                  :mat3x2 :mat3x3 :mat3x4
                                  :mat4x2 :mat4x3 :mat4x4))))
            :output-type '(1 nil)
            :transform "(~a * ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '*
            :in-args '((x ((:vec2 :vec3 :vec4
                                  :ivec2 :ivec3 :ivec4
                                  :mat2 :mat3 :mat4 
                                  :mat2x2 :mat2x3 :mat2x4
                                  :mat3x2 :mat3x3 :mat3x4
                                  :mat4x2 :mat4x3 :mat4x4)))
                       (y ((:int :float))))
            :output-type '(0 nil)
            :transform "(~a * ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '*
            :in-args '((x ((:vec2 :vec3 :vec4
                                  :ivec2 :ivec3 :ivec4)) :compatible)
                       (y ((:vec2 :vec3 :vec4
                                  :ivec2 :ivec3 :ivec4)) :compatible))
            :output-type '(0 nil)
            :transform "(~a * ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '*
            :in-args '((x ((:mat2 :mat2x2 :mat2x3 :mat2x4)))
                       (y ((:vec2 :ivec2))))
            :output-type '(1 nil)
            :transform "(~a * ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '*
            :in-args '((x ((:mat3 :mat3x2 :mat3x3 :mat3x4)))
                       (y ((:vec3 :ivec3))))
            :output-type '(1 nil)
            :transform "(~a * ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '*
            :in-args '((x ((:mat4 :mat4x2 :mat4x3 :mat4x4)))
                       (y ((:vec4 :ivec4))))
            :output-type '(1 nil)
            :transform "(~a * ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '*
            :in-args '((x ((:mat2 :mat3 :mat4)) :compatible)
                       (y ((:mat2 :mat3 :mat4)) :compatible))
            :output-type '(1 nil)
            :transform "(~a * ~a)"
            :context-restriction '((:330)))


(glsl-defun :name '%
            :in-args '((x ((:int :uint :ivec2 :uvec2 
                                 :ivec3 :uvec3 :ivec4 :uvec4)))
                       (y ((:int :uint))))
            :output-type '(0 nil)
            :transform "(~a % ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '<
            :in-args '((x ((:float :int)))
                       (y ((:float :int))))
            :output-type '(:bool nil)
            :transform "(~a < ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '>
            :in-args '((x ((:float :int)))
                       (y ((:float :int))))
            :output-type '(:bool nil)
            :transform "(~a > ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '<=
            :in-args '((x ((:float :int)))
                       (y ((:float :int))))
            :output-type '(:bool nil)
            :transform "(~a <= ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '>=
            :in-args '((x ((:float :int)))
                       (y ((:float :int))))
            :output-type '(:bool nil)
            :transform "(~a >= ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '==
            :in-args '((a (t t) :compatible)
                       (b (t t) :compatible))
            :output-type '(:bool nil)
            :transform "(~a == ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '!=
            :in-args '((a (t t) :compatible)
                       (b (t t) :compatible))
            :output-type '(:bool nil)
            :transform "(~a != ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '==
            :in-args '((a (t nil) :compatible)
                       (b (t nil) :compatible))
            :output-type '(:bool nil)
            :transform "(~a == ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '!=
            :in-args '((a (t nil) :compatible)
                       (b (t nil) :compatible))
            :output-type '(:bool nil)
            :transform "(~a != ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '!
            :in-args '((a (:bool nil)))
            :output-type '(:bool nil)
            :transform "(! ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '~
            :in-args '((a ((:int :uint :ivec2 :ivec3 :ivec4) 
                           nil)))
            :output-type '(0 nil)
            :transform "(~ ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '<<
            :in-args '((a ((:int :uint :float) nil))
                       (b ((:int :uint :float) nil)))
            :output-type '(0 nil)
            :transform "(~a << ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '<<
            :in-args '((a ((:ivec2 :ivec3 :ivec4
                                   :uvec2 :uvec3 :uvec4) nil))
                       (b ((:int :uint :float) nil)))
            :output-type '(0 nil)
            :transform "(~a << ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '<<
            :in-args '((a ((:ivec2 :ivec3 :ivec4
                                   :uvec2 :uvec3 :uvec4) nil) :compatible)
                       (b ((:ivec2 :ivec3 :ivec4
                                   :uvec2 :uvec3 :uvec4) nil) :compatible))
            :output-type '(0 nil)
            :transform "(~a << ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '>>
            :in-args '((a ((:int :uint :float) nil))
                       (b ((:int :uint :float) nil)))
            :output-type '(0 nil)
            :transform "(~a >> ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '>>
            :in-args '((a ((:ivec2 :ivec3 :ivec4
                                   :uvec2 :uvec3 :uvec4) nil))
                       (b ((:int :uint :float) nil)))
            :output-type '(0 nil)
            :transform "(~a >> ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '>>
            :in-args '((a ((:ivec2 :ivec3 :ivec4
                                   :uvec2 :uvec3 :uvec4) nil) :compatible)
                       (b ((:ivec2 :ivec3 :ivec4
                                   :uvec2 :uvec3 :uvec4) nil) :compatible))
            :output-type '(0 nil)
            :transform "(~a >> ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '&
            :in-args '((a ((:int :uint
                                 :ivec2 :ivec3 :ivec4
                                 :uvec2 :uvec3 :uvec4) nil) :match)
                       (b ((:int :uint
                                 :ivec2 :ivec3 :ivec4
                                 :uvec2 :uvec3 :uvec4) nil) :match))
            :output-type '(0 nil)
            :transform "(~a & ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '^
            :in-args '((a ((:int :uint
                                 :ivec2 :ivec3 :ivec4
                                 :uvec2 :uvec3 :uvec4) nil) :match)
                       (b ((:int :uint
                                 :ivec2 :ivec3 :ivec4
                                 :uvec2 :uvec3 :uvec4) nil) :match))
            :output-type '(0 nil)
            :transform "(~a ^ ~a)"
            :context-restriction '((:330)))

(glsl-defun :name 'pipe
            :in-args '((a ((:int :uint
                                 :ivec2 :ivec3 :ivec4
                                 :uvec2 :uvec3 :uvec4) nil) :match)
                       (b ((:int :uint
                                 :ivec2 :ivec3 :ivec4
                                 :uvec2 :uvec3 :uvec4) nil) :match))
            :output-type '(0 nil)
            :transform "(~a | ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '&&
            :in-args '((a (:bool nil))
                       (b (:bool nil)))
            :output-type '(0 nil)
            :transform "(~a && ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '^^
            :in-args '((a (:bool nil))
                       (b (:bool nil)))
            :output-type '(0 nil)
            :transform "(~a && ~a)"
            :context-restriction '((:330)))

(glsl-defun :name '||
            :in-args '((a (:bool nil))
                       (b (:bool nil)))
            :output-type '(0 nil)
            :transform "(~a && ~a)"
            :context-restriction '((:330)))

;;------------------------------------------------------------
;; Lisp Function Substitutions
;;-----------------------------

(%vdefmacro - t nil (&rest args)
  (if (eq 1 (length args))
      `(%negate ,@args)
      `(%- ,@args)))

(%vdefmacro * t nil (&rest args)
  (oper-segment-list args '*))

(%vdefmacro / t nil (&rest args)
  (oper-segment-list args '/))

(%vdefmacro v! t nil (&rest args)
  (let ((len (length args)))
    (when (or (>= len 2) (<= len 4)))
    `(%init-vec-or-mat ,(kwd (symb :vec (length args))) ,@args)))

(%vdefmacro m! t nil (&rest args)
  (let ((len (length args)))
    (if (or (eq len 4) (eq len 9) (eq len 16))
        `(%init-vec-or-mat ,(kwd (symb :mat (floor (sqrt len))))
                           ,@args)
        (error "Invalid number of arguemnts for matrix"))))

(%vdefmacro vec2 t nil (&rest args)
  `(%init-vec-or-mat :vec2 ,@args))

(%vdefmacro vec3 t nil (&rest args)
  `(%init-vec-or-mat :vec3 ,@args))

(%vdefmacro vec4 t nil (&rest args)
  `(%init-vec-or-mat :vec4 ,@args))

(%vdefmacro ivec2 t nil (&rest args)
  `(%init-vec-or-mat :ivec2 ,@args))

(%vdefmacro ivec3 t nil (&rest args)
  `(%init-vec-or-mat :ivec3 ,@args))

(%vdefmacro ivec4 t nil (&rest args)
  `(%init-vec-or-mat :ivec4 ,@args))

(%vdefmacro uvec2 t nil (&rest args)
  `(%init-vec-or-mat :uvec2 ,@args))

(%vdefmacro uvec3 t nil (&rest args)
  `(%init-vec-or-mat :uvec3 ,@args))

(%vdefmacro uvec4 t nil (&rest args)
  `(%init-vec-or-mat :uvec4 ,@args))

(%vdefmacro mat2 t nil (&rest args)
  `(%init-vec-or-mat :mat2 ,@args))

(%vdefmacro mat3 t nil (&rest args)
  `(%init-vec-or-mat :mat3 ,@args))

(%vdefmacro mat4 t nil (&rest args)
  `(%init-vec-or-mat :mat4 ,@args))

(%vdefmacro mat2x2 t nil (&rest args)
  `(%init-vec-or-mat :mat2x2 ,@args))

(%vdefmacro mat2x3 t nil (&rest args)
  `(%init-vec-or-mat :mat2x3 ,@args))

(%vdefmacro mat2x4 t nil (&rest args)
  `(%init-vec-or-mat :mat2x4 ,@args))

(%vdefmacro mat3x2 t nil (&rest args)
  `(%init-vec-or-mat :mat3x2 ,@args))

(%vdefmacro mat3x3 t nil (&rest args)
  `(%init-vec-or-mat :mat3x3 ,@args))

(%vdefmacro mat3x4 t nil (&rest args)
  `(%init-vec-or-mat :mat3x4 ,@args))

(%vdefmacro mat4x2 t nil (&rest args)
  `(%init-vec-or-mat :mat4x2 ,@args))

(%vdefmacro mat4x3 t nil (&rest args)
  `(%init-vec-or-mat :mat4x3 ,@args))

(%vdefmacro mat4x4 t nil (&rest args)
  `(%init-vec-or-mat :mat4x4 ,@args))

(%vdefmacro while t nil (test &rest body)
  `(while ,test (progn ,@body)))

(%vdefmacro let* t nil (bindings &rest body)
  (let* ((bindings (reverse bindings))
         (result `(let (,(first bindings))
                    ,@body)))
    (loop for binding in (rest bindings) do
         (setf result `(let (,binding) ,result)))
    result))

;;------------------------------------------------------------
;; Texture Lookup Functions
;;-------------------------
;; :in-args '((vec ((:vec2 :vec3 :vec4))))

;;---texture size---
(glsl-defun 
 :name 'texture-size 
 :in-args '((sampler ((:sampler-1d :isampler-1d :usampler-1d
                                   :sampler-1d-shadow))) (lod :int))
 :output-type :int 
 :transform "textureSize(~a, ~a)"
 :context-restriction '((:330)))

(glsl-defun 
 :name 'texture-size 
 :in-args '((sampler ((:sampler-2d :isampler-2d :usampler-2d :sampler-cube
                                   :isampler-cube :usampler-cube :sampler-2d-shadow
                                   :sampler-cube-shadow :sampler-2d-rect
                                   :isampler-2d-rect :usampler-2d-rect
                                   :sampler-2d-rect-shadow :isampler-2d-rect-shadow
                                   :usampler-2d-rect-shadow :sampler-1d-array
                                   :isampler-1d-array :usampler-1d-array
                                   :sampler-1d-array-shadow))) (lod :int))
 :output-type :ivec2 
 :transform "textureSize(~a, ~a)"
 :context-restriction '((:330)))

(glsl-defun 
 :name 'texture-size 
 :in-args '((sampler ((:sampler-3d :isampler-3d :usampler-3d :sampler-cube-array
                                   :sampler-cube-array-shadow :sampler-2d-array
                                   :isampler-2d-array :usampler-2d-array
                                   :sampler-2d-array-shadow ))) (lod :int))
 :output-type :ivec3 
 :transform "textureSize(~a, ~a)"
 :context-restriction '((:330)))

(glsl-defun 
 :name 'texture-size 
 :in-args '((sampler ((:sampler-buffer :isampler-buffer :usampler-buffer))))
 :output-type :int 
 :transform "textureSize(~a, ~a)"
 :context-restriction '((:330)))

(glsl-defun 
 :name 'texture-size 
 :in-args '((sampler ((:sampler-2d-ms :isampler-2d-ms :usampler-2d-ms))))
 :output-type :ivec2 
 :transform "textureSize(~a, ~a)"
 :context-restriction '((:330)))

(glsl-defun 
 :name 'texture-size 
 :in-args '((sampler ((:sampler-2d-ms-array :isampler-2d-ms-array :usampler-2d-ms-array))))
 :output-type :ivec3 
 :transform "textureSize(~a, ~a)"
 :context-restriction '((:330)))

;;-----texture-----
;; [TODO] This whole section needs reworking... it is wrong

(glsl-multi-defun 
 :name 'texture 
 :specs '((:in ((sampler :isampler-1d) (P :float) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-1d-array) (P :vec2) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec2) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-2d-array) (P :vec3) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec3) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-cube) (P :vec3) (bias :float)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :float) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-1d-array) (P :vec2) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-1d-array-shadow) (P :vec3) (bias :float)) :out :float)
          (:in ((sampler :isampler-2d-array-shadow) (P :vec3) (bias :float)) :out :float)
          (:in ((sampler :sampler-2d-array-shadow) (P :vec3) (bias :float)) :out :float)
          (:in ((sampler :sampler-1d-shadow) (P :vec3) (bias :float)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec2) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-2d-array) (P :vec3) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-2d-shadow) (P :vec3) (bias :float)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec3) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-cube) (P :vec3) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-cube-shadow) (P :vec4) (bias :float)) :out :float)          
          (:in ((sampler :usampler-1d) (P :float) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-1d-array) (P :vec2) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec2) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-2d-array) (P :vec3) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec3) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-cube) (P :vec3) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-2d-array-shadow) (P :vec3) (bias :float)) :out :float)
          (:in ((sampler :sampler-cube-array-shadow) (P :vec4) (compare :float)) :out :float)
          (:in ((sampler :isampler-cube-array-shadow) (P :vec4) (compare :float)) :out :float)
          (:in ((sampler :usampler-cube-array-shadow) (P :vec4) (compare :float)) :out :float))
 :transform "texture(~a, ~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texture 
 :specs '((:in ((sampler :isampler-1d) (P :float)) :out :ivec4)
          (:in ((sampler :isampler-1d-array) (P :vec2)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec2)) :out :ivec4)
          (:in ((sampler :isampler-2d-array) (P :vec3)) :out :ivec4)
          (:in ((sampler :isampler-2d-rect) (P :vec2)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec3)) :out :ivec4)
          (:in ((sampler :isampler-cube) (P :vec3)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :float)) :out :vec4)
          (:in ((sampler :sampler-1d-array) (P :vec2)) :out :vec4)
          (:in ((sampler :sampler-1d-array-shadow) (P :vec3)) :out :float)
          (:in ((sampler :sampler-1d-shadow) (P :vec3)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec2)) :out :vec4)
          (:in ((sampler :sampler-2d-array) (P :vec3)) :out :vec4)
          (:in ((sampler :sampler-2d-array-shadow) (P :vec4)) :out :float)
          (:in ((sampler :isampler-2d-array-shadow) (P :vec4)) :out :float)
          (:in ((sampler :usampler-2d-array-shadow) (P :vec4)) :out :float)
          (:in ((sampler :sampler-2d-rect) (P :vec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect-shadow) (P :vec3)) :out :float)
          (:in ((sampler :sampler-2d-shadow) (P :vec3)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec3)) :out :vec4)
          (:in ((sampler :sampler-cube) (P :vec3)) :out :vec4)
          (:in ((sampler :sampler-cube-shadow) (P :vec4)) :out :float)
          (:in ((sampler :usampler-1d) (P :float)) :out :uvec4)
          (:in ((sampler :usampler-1d-array) (P :vec2)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec2)) :out :uvec4)
          (:in ((sampler :usampler-2d-array) (P :vec3)) :out :uvec4)
          (:in ((sampler :usampler-2d-rect) (P :vec2)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec3)) :out :uvec4)
          (:in ((sampler :usampler-cube) (P :vec3)) :out :uvec4))
 :transform "texture(~a, ~a)"
 :context-restriction '((:330)))
(glsl-multi-defun
 :name 'texture-proj
 :specs '((:in ((sampler :isampler-1d) (P :vec2)) :out :ivec4)
          (:in ((sampler :isampler-1d) (P :vec4)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec3)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec4)) :out :ivec4)
          (:in ((sampler :isampler-2d-rect) (P :vec3)) :out :ivec4)
          (:in ((sampler :isampler-2d-rect) (P :vec4)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec4)) :out :ivec4)
          (:in ((sampler :isampler-2d-rect-shadow) (P :vec4)) :out :float) 
          (:in ((sampler :sampler-1d) (P :vec2)) :out :vec4)
          (:in ((sampler :sampler-1d) (P :vec4)) :out :vec4)
          (:in ((sampler :sampler-1d-shadow) (P :vec4)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec3)) :out :vec4)
          (:in ((sampler :sampler-2d) (P :vec4)) :out :vec4)
          (:in ((sampler :sampler-2d-rect) (P :vec3)) :out :vec4)
          (:in ((sampler :sampler-2d-rect) (P :vec4)) :out :vec4)
          (:in ((sampler :sampler-2d-rect-shadow) (P :vec4)) :out :float)
          (:in ((sampler :sampler-2d-shadow) (P :vec4)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec4)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :vec2)) :out :uvec4)
          (:in ((sampler :usampler-1d) (P :vec4)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec3)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec4)) :out :uvec4)
          (:in ((sampler :usampler-2d-rect) (P :vec3)) :out :uvec4)
          (:in ((sampler :usampler-2d-rect) (P :vec4)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec4)) :out :uvec4)
          (:in ((sampler :usampler-2d-rect-shadow) (P :vec4)) :out :float))
 :transform "textureProj(~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun
 :name 'texture-proj
 :specs '((:in ((sampler :isampler-1d) (P :vec2) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-1d) (P :vec4) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec3) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec4) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec4) (bias :float)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :vec2) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-1d) (P :vec4) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-1d-shadow) (P :vec4) (bias :float)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec3) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-2d) (P :vec4) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-2d-rect) (P :vec3) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-2d-rect) (P :vec4) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-2d-shadow) (P :vec4) (bias :float)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec4) (bias :float)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :vec2) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-1d) (P :vec4) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec3) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec4) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-2d-rect) (P :vec3) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-2d-rect) (P :vec4) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec4) (bias :float)) :out :uvec4))
 :transform "textureProj(~a, ~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texture-lod 
 :specs '((:in ((sampler :isampler-1d) (P :float) (lod :float)) :out :ivec4)
          (:in ((sampler :isampler-1d-array) (P :vec2) (lod :float)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec2) (lod :float)) :out :ivec4)
          (:in ((sampler :isampler-2d-array) (P :vec3) (lod :float)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec3) (lod :float)) :out :ivec4)
          (:in ((sampler :isampler-cube) (P :vec3) (lod :float)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :float) (lod :float)) :out :vec4)
          (:in ((sampler :sampler-1d-array) (P :vec2) (lod :float)) :out :vec4)
          (:in ((sampler :sampler-1d-array-shadow) (P :vec3) (lod :float)) :out :float)
          (:in ((sampler :sampler-1d-shadow) (P :vec3) (lod :float)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec2) (lod :float)) :out :vec4)
          (:in ((sampler :sampler-2d-array) (P :vec3) (lod :float)) :out :ivec4)
          (:in ((sampler :sampler-2d-shadow) (P :vec3) (lod :float)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec3) (lod :float)) :out :vec4)
          (:in ((sampler :sampler-cube) (P :vec3) (lod :float)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :float) (lod :float)) :out :uvec4)
          (:in ((sampler :usampler-1d-array) (P :vec2) (lod :float)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec2) (lod :float)) :out :uvec4)
          (:in ((sampler :usampler-2d-array) (P :vec3) (lod :float)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec3) (lod :float)) :out :uvec4)
          (:in ((sampler :usampler-cube) (P :vec3) (lod :float)) :out :uvec4))
 :transform "textureLod(~a, ~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texture-offset 
 :specs '((:in ((sampler :isampler-1d) (P :float) (offset :int) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-1d-array) (P :vec2) (offset :int) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec2) (offset :ivec2) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-2d-array) (P :vec3) (offset :ivec2) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec3) (offset :ivec3) (bias :float)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :float) (offset :int) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-1d-array) (P :vec2) (offset :int) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-1d-array-shadow) (P :vec3) (offset :int) (bias :float)) :out :float)
          (:in ((sampler :sampler-1d-shadow) (P :vec3) (offset :int) (bias :float)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec2) (offset :ivec2) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-2d-array) (P :vec3) (offset :ivec2) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-2d-shadow) (P :vec3) (offset :ivec2) (bias :float)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec3) (offset :ivec3) (bias :float)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :float) (offset :int) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-1d-array) (P :vec2) (offset :int) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec2) (offset :ivec2) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-2d-array) (P :vec3) (offset :ivec2) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec3) (offset :ivec3) (bias :float)) :out :uvec4))
 :transform "textureOffset(~a, ~a, ~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texture-offset 
 :specs '((:in ((sampler :isampler-1d) (P :float) (offset :int)) :out :ivec4)
          (:in ((sampler :isampler-1d-array) (P :vec2) (offset :int)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec2) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-2d-array) (P :vec3) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-2d-rect) (P :vec2) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec3) (offset :ivec3)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :float) (offset :int)) :out :vec4)
          (:in ((sampler :sampler-1d-array) (P :vec2) (offset :int)) :out :vec4)
          (:in ((sampler :sampler-1d-array-shadow) (P :vec3) (offset :int)) :out :float)
          (:in ((sampler :sampler-1d-shadow) (P :vec3) (offset :int)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec2) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-array) (P :vec3) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect) (P :vec2) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect-shadow) (P :vec3) (offset :ivec2)) :out :float)
          (:in ((sampler :sampler-2d-shadow) (P :vec3) (offset :ivec2)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec3) (offset :ivec3)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :float) (offset :int)) :out :uvec4)
          (:in ((sampler :usampler-1d-array) (P :vec2) (offset :int)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec2) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-2d-array) (P :vec3) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-2d-rect) (P :vec2) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec3) (offset :ivec3)) :out :uvec4))
 :transform "textureOffset(~a, ~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texel-fetch 
 :specs '((:in ((sampler :isampler-1d) (P :int) (lod :int)) :out :ivec4)
          (:in ((sampler :isampler-1d-array) (P :ivec2) (lod :int)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :ivec2) (lod :int)) :out :ivec4)
          (:in ((sampler :isampler-2d-array) (P :ivec3) (lod :int)) :out :ivec4)
          (:in ((sampler :isampler-2d-ms) (P :ivec2) (sample :int)) :out :ivec4)
          (:in ((sampler :isampler-2d-ms-array) (P :ivec3) (sample :int)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :ivec3) (lod :int)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :int) (lod :int)) :out :vec4)
          (:in ((sampler :sampler-1d-array) (P :ivec2) (lod :int)) :out :vec4)
          (:in ((sampler :sampler-2d) (P :ivec2) (lod :int)) :out :vec4)
          (:in ((sampler :sampler-2d-array) (P :ivec3) (lod :int)) :out :vec4)
          (:in ((sampler :sampler-2d-ms) (P :ivec2) (sample :int)) :out :vec4)
          (:in ((sampler :sampler-2d-ms-array) (P :ivec3) (sample :int)) :out :vec4)
          (:in ((sampler :sampler-3d) (P :ivec3) (lod :int)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :int) (lod :int)) :out :uvec4)
          (:in ((sampler :usampler-1d-array) (P :ivec2) (lod :int)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :ivec2) (lod :int)) :out :uvec4)
          (:in ((sampler :usampler-2d-array) (P :ivec3) (lod :int)) :out :uvec4)
          (:in ((sampler :usampler-2d-ms) (P :ivec2) (sample :int)) :out :uvec4)
          (:in ((sampler :usampler-2d-ms-array) (P :ivec3) (sample :int)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :ivec3) (lod :int)) :out :uvec4))
 :transform "texelFetch(~a, ~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texel-fetch 
 :specs '((:in ((sampler :isampler-2d-rect) (P :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-buffer) (P :int)) :out :ivec4)
          (:in ((sampler :sampler-2d-rect) (P :ivec2)) :out :vec4)
          (:in ((sampler :sampler-buffer) (P :int)) :out :vec4)
          (:in ((sampler :usampler-2d-rect) (P :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-buffer) (P :int)) :out :uvec4))
 :transform "texelFetch(~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texel-fetch-offset 
 :specs '((:in ((sampler :isampler-1d) (P :int) (lod :int) (offset :int)) :out :ivec4)
          (:in ((sampler :isampler-1d-array) (P :ivec2) (lod :int) (offset :int)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :ivec2) (lod :int) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-2d-array) (P :ivec3) (lod :int) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :ivec3) (lod :int) (offset :ivec3)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :int) (lod :int) (offset :int)) :out :vec4)
          (:in ((sampler :sampler-1d-array) (P :ivec2) (lod :int) (offset :int)) :out :vec4)
          (:in ((sampler :sampler-2d) (P :ivec2) (lod :int) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-array) (P :ivec3) (lod :int) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect) (P :ivec2) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-3d) (P :ivec3) (lod :int) (offset :ivec3)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :int) (lod :int) (offset :int)) :out :uvec4)
          (:in ((sampler :usampler-1d-array) (P :ivec2) (lod :int) (offset :int)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :ivec2) (lod :int) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-2d-array) (P :ivec3) (lod :int) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :ivec3) (lod :int) (offset :ivec3)) :out :uvec4))
 :transform "texelFetchOffset(~a, ~a, ~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texel-fetch-offset 
 :specs '((:in ((sampler :isampler-2d-rect) (P :ivec2) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :usampler-2d-rect) (P :ivec2) (offset :ivec2)) :out :uvec4))
 :transform "texelFetchOffset(~a, ~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texture-proj-offset 
 :specs '((:in ((sampler :isampler-1d) (P :vec2) (offset :int) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-1d) (P :vec4) (offset :int) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec3) (offset :ivec2) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec4) (offset :ivec2) (bias :float)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec4) (offset :ivec3) (bias :float)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :vec2) (offset :int) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-1d) (P :vec4) (offset :int) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-1d-shadow) (P :vec4) (offset :int) (bias :float)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec3) (offset :ivec2) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-2d) (P :vec4) (offset :ivec2) (bias :float)) :out :vec4)
          (:in ((sampler :sampler-2d-shadow) (P :vec4) (offset :ivec2) (bias :float)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec4) (offset :ivec3) (bias :float)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :vec2) (offset :int) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-1d) (P :vec4) (offset :int) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec3) (offset :ivec2) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec4) (offset :ivec2) (bias :float)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec4) (offset :ivec3) (bias :float)) :out :uvec4))
 :transform "textureProjOffset(~a, ~a, ~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texture-proj-offset 
 :specs '((:in ((sampler :isampler-1d) (P :vec2) (offset :int)) :out :ivec4)
          (:in ((sampler :isampler-1d) (P :vec4) (offset :int)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec3) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec4) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-2d-rect) (P :vec3) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-2d-rect) (P :vec4) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec4) (offset :ivec3)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :vec2) (offset :int)) :out :vec4)
          (:in ((sampler :sampler-1d) (P :vec4) (offset :int)) :out :vec4)
          (:in ((sampler :sampler-1d-shadow) (P :vec4) (offset :int)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec3) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d) (P :vec4) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect) (P :vec3) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect) (P :vec4) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect-shadow) (P :vec4) (offset :ivec2)) :out :float)
          (:in ((sampler :sampler-2d-shadow) (P :vec4) (offset :ivec2)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec4) (offset :ivec3)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :vec2) (offset :int)) :out :uvec4)
          (:in ((sampler :usampler-1d) (P :vec4) (offset :int)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec3) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec4) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-2d-rect) (P :vec3) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-2d-rect) (P :vec4) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec4) (offset :ivec3)) :out :uvec4))
 :transform "textureProjOffset(~a, ~a, ~a)"
 :context-restriction '((:330)))


(glsl-multi-defun 
 :name 'texture-lod-offset
 :specs '((:in ((sampler :isampler-1d) (P :float) (lod :float) (offset :int)) :out :ivec4)
          (:in ((sampler :isampler-1d-array) (P :vec2) (lod :float) (offset :int)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec2) (lod :float) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-2d-array) (P :vec3) (lod :float) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec3) (lod :float) (offset :ivec3)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :float) (lod :float) (offset :int)) :out :vec4)
          (:in ((sampler :sampler-1d-array) (P :vec2) (lod :float) (offset :int)) :out :vec4)
          (:in ((sampler :sampler-1d-array-shadow) (P :vec3) (lod :float) (offset :int)) :out :float)
          (:in ((sampler :sampler-1d-shadow) (P :vec3) (lod :float) (offset :int)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec2) (lod :float) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-array) (P :vec3) (lod :float) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-shadow) (P :vec3) (lod :float) (offset :ivec2)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec3) (lod :float) (offset :ivec3)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :float) (lod :float) (offset :int)) :out :uvec4)
          (:in ((sampler :usampler-1d-array) (P :vec2) (lod :float) (offset :int)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec2) (lod :float) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-2d-array) (P :vec3) (lod :float) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec3) (lod :float) (offset :ivec3)) :out :uvec4))
 :transform "textureLodOffset(~a, ~a, ~a, ~a)"
 :context-restriction '((:330)))


(glsl-multi-defun 
 :name 'texture-proj-lod 
 :specs '((:in ((sampler :isampler-1d) (P :vec2) (lod :float)) :out :ivec4)
          (:in ((sampler :isampler-1d) (P :vec4) (lod :float)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec3) (lod :float)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec4) (lod :float)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec4) (lod :float)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :vec4) (lod :float)) :out :vec4)
          (:in ((sampler :sampler-1d-shadow) (P :vec4) (lod :float)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec3) (lod :float)) :out :vec4)
          (:in ((sampler :sampler-2d) (P :vec4) (lod :float)) :out :vec4)
          (:in ((sampler :sampler-2d-shadow) (P :vec4) (lod :float)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec4) (lod :float)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :vec2) (lod :float)) :out :uvec4)
          (:in ((sampler :usampler-1d) (P :vec4) (lod :float)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec3) (lod :float)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec4) (lod :float)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec4) (lod :float)) :out :uvec4))
 :transform "textureProjLod(~a, ~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texture-proj-lod-offset 
 :specs '((:in ((sampler :isampler-1d) (P :vec2) (lod :float) (offset :int)) :out :ivec4)
          (:in ((sampler :isampler-1d) (P :vec4) (lod :float) (offset :int)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec3) (lod :float) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec4) (lod :float) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec4) (lod :float) (offset :ivec3)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :vec2) (lod :float) (offset :int)) :out :vec4)
          (:in ((sampler :sampler-1d) (P :vec4) (lod :float) (offset :int)) :out :vec4)
          (:in ((sampler :sampler-1d-shadow) (P :vec4) (lod :float) (offset :int)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec3) (lod :float) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d) (P :vec4) (lod :float) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-shadow) (P :vec4) (lod :float) (offset :ivec2)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec4) (lod :float) (offset :ivec3)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :vec2) (lod :float) (offset :int)) :out :uvec4)
          (:in ((sampler :usampler-1d) (P :vec4) (lod :float) (offset :int)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec3) (lod :float) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec4) (lod :float) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec4) (lod :float) (offset :ivec3)) :out :uvec4))
 :transform "textureProjLodOffset(~a, ~a, ~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texture-grad 
 :specs '((:in ((sampler :isampler-1d) (P :float) (dPdx :float) (dPdy :float)) :out :ivec4)
          (:in ((sampler :isampler-1d-array) (P :vec2) (dPdx :float) (dPdy :float)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec2) (dPdx :vec2) (dPdy :vec2)) :out :ivec4)
          (:in ((sampler :isampler-2d-array) (P :vec3) (dPdx :vec2) (dPdy :vec2)) :out :ivec4)
          (:in ((sampler :isampler-2d-rect) (P :vec2) (dPdx :vec2) (dPdy :vec2)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec3) (dPdx :vec3) (dPdy :vec3)) :out :ivec4)
          (:in ((sampler :isampler-cube) (P :vec3) (dPdx :vec3) (dPdy :vec3)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :float) (dPdx :float) (dPdy :float)) :out :vec4)
          (:in ((sampler :sampler-1d-array) (P :vec2) (dPdx :float) (dPdy :float)) :out :vec4)
          (:in ((sampler :sampler-1d-array-shadow) (P :vec3) (dPdx :float) (dPdy :float)) :out :float)
          (:in ((sampler :sampler-1d-shadow) (P :vec3) (dPdx :float) (dPdy :float)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec2) (dPdx :vec2) (dPdy :vec2)) :out :vec4)
          (:in ((sampler :sampler-2d-array) (P :vec3) (dPdx :vec2) (dPdy :vec2)) :out :vec4)
          (:in ((sampler :sampler-2d-array-shadow) (P :vec4) (dPdx :vec2) (dPdy :vec2)) :out :float)
          (:in ((sampler :sampler-2d-rect) (P :vec2) (dPdx :vec2) (dPdy :vec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect-shadow) (P :vec3) (dPdx :vec2) (dPdy :vec2)) :out :float)
          (:in ((sampler :sampler-2d-shadow) (P :vec3) (dPdx :vec2) (dPdy :vec2)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec3) (dPdx :vec3) (dPdy :vec3)) :out :vec4)
          (:in ((sampler :sampler-cube) (P :vec3) (dPdx :vec3) (dPdy :vec3)) :out :vec4)
          (:in ((sampler :sampler-cube-shadow) (P :vec4) (dPdx :vec3) (dPdy :vec3)) :out :float)
          (:in ((sampler :usampler-1d) (P :float) (dPdx :float) (dPdy :float)) :out :uvec4)
          (:in ((sampler :usampler-1d-array) (P :vec2) (dPdx :float) (dPdy :float)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec2) (dPdx :vec2) (dPdy :vec2)) :out :uvec4)
          (:in ((sampler :usampler-2d-array) (P :vec3) (dPdx :vec2) (dPdy :vec2)) :out :uvec4)
          (:in ((sampler :usampler-2d-rect) (P :vec2) (dPdx :vec2) (dPdy :vec2)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec3) (dPdx :vec3) (dPdy :vec3)) :out :uvec4)
          (:in ((sampler :usampler-cube) (P :vec3) (dPdx :vec3) (dPdy :vec3)) :out :uvec4))
 :transform "textureGrad(~a, ~a, ~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texture-grad-offset 
 :specs '((:in ((sampler :isampler-1d) (P :float) (dPdx :float) (dPdy :float) (offset :int)) :out :ivec4)
          (:in ((sampler :isampler-1d-array) (P :vec2) (dPdx :float) (dPdy :float) (offset :int)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec2) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-2d-array) (P :vec3) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-2d-rect) (P :vec2) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec3) (dPdx :vec3) (dPdy :vec3) (offset :ivec3)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :float) (dPdx :float) (dPdy :float) (offset :int)) :out :vec4)
          (:in ((sampler :sampler-1d-array) (P :vec2) (dPdx :float) (dPdy :float) (offset :int)) :out :vec4)
          (:in ((sampler :sampler-1d-array-shadow) (P :vec3) (dPdx :float) (dPdy :float) (offset :int)) :out :float)
          (:in ((sampler :sampler-1d-shadow) (P :vec3) (dPdx :float) (dPdy :float) (offset :int)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec2) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-array) (P :vec3) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-array-shadow) (P :vec4) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :float)
          (:in ((sampler :sampler-2d-rect) (P :vec2) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect-shadow) (P :vec3) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :float)
          (:in ((sampler :sampler-2d-shadow) (P :vec3) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec3) (dPdx :vec3) (dPdy :vec3) (offset :ivec3)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :float) (dPdx :float) (dPdy :float) (offset :int)) :out :uvec4)
          (:in ((sampler :usampler-1d-array) (P :vec2) (dPdx :float) (dPdy :float) (offset :int)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec2) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-2d-array) (P :vec3) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-2d-rect) (P :vec2) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec3) (dPdx :vec3) (dPdy :vec3) (offset :ivec3)) :out :uvec4))
 :transform "textureGradOffset(~a, ~a, ~a, ~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texture-proj-grad 
 :specs '((:in ((sampler :isampler-1d) (P :vec2) (dPdx :float) (dPdy :float)) :out :ivec4)
          (:in ((sampler :isampler-1d) (P :vec4) (dPdx :float) (dPdy :float)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec3) (dPdx :vec2) (dPdy :vec2)) :out :ivec4)
          (:in ((sampler :isampler-2d) (P :vec4) (dPdx :vec2) (dPdy :vec2)) :out :ivec4)
          (:in ((sampler :isampler-2d-rect) (P :vec3) (dPdx :vec2) (dPdy :vec2)) :out :ivec4)
          (:in ((sampler :isampler-2d-rect) (P :vec4) (dPdx :vec2) (dPdy :vec2)) :out :ivec4)
          (:in ((sampler :isampler-3d) (P :vec4) (dPdx :vec3) (dPdy :vec3)) :out :ivec4)
          (:in ((sampler :sampler-1d) (P :vec2) (dPdx :float) (dPdy :float)) :out :vec4)
          (:in ((sampler :sampler-1d) (P :vec4) (dPdx :float) (dPdy :float)) :out :vec4)
          (:in ((sampler :sampler-1d-shadow) (P :vec4) (dPdx :float) (dPdy :float)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec3) (dPdx :vec2) (dPdy :vec2)) :out :vec4)
          (:in ((sampler :sampler-2d) (P :vec4) (dPdx :vec2) (dPdy :vec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect) (P :vec3) (dPdx :vec2) (dPdy :vec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect) (P :vec4) (dPdx :vec2) (dPdy :vec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect-shadow) (P :vec4) (dPdx :vec2) (dPdy :vec2)) :out :float)
          (:in ((sampler :sampler-2d-shadow) (P :vec4) (dPdx :vec2) (dPdy :vec2)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec4) (dPdx :vec3) (dPdy :vec3)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :vec2) (dPdx :float) (dPdy :float)) :out :uvec4)
          (:in ((sampler :usampler-1d) (P :vec4) (dPdx :float) (dPdy :float)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec3) (dPdx :vec2) (dPdy :vec2)) :out :uvec4)
          (:in ((sampler :usampler-2d) (P :vec4) (dPdx :vec2) (dPdy :vec2)) :out :uvec4)
          (:in ((sampler :usampler-2d-rect) (P :vec3) (dPdx :vec2) (dPdy :vec2)) :out :uvec4)
          (:in ((sampler :usampler-2d-rect) (P :vec4) (dPdx :vec2) (dPdy :vec2)) :out :uvec4)
          (:in ((sampler :usampler-3d) (P :vec4) (dPdx :vec3) (dPdy :vec3)) :out :uvec4))
 :transform "textureProjGrad(~a, ~a, ~a, ~a)"
 :context-restriction '((:330)))

(glsl-multi-defun 
 :name 'texture-proj-grad-offset 
 :specs '((:in ((sampler :isampler-1d) (P :vec2) (dPdx :float) (dPdy :float) (offset :int)) :out :uvec4)
          (:in ((sampler :isampler-1d) (P :vec4) (dPdx :float) (dPdy :float) (offset :int)) :out :uvec4)
          (:in ((sampler :isampler-2d) (P :vec3) (dPdx :vec2) (dPdy :vec2) (offset :vec2)) :out :uvec4)
          (:in ((sampler :isampler-2d) (P :vec4) (dPdx :vec2) (dPdy :vec2) (offset :vec2)) :out :uvec4)
          (:in ((sampler :isampler-2d-rect) (P :vec3) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :isampler-2d-rect) (P :vec4) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :uvec4)
          (:in ((sampler :isampler-3d) (P :vec4) (dPdx :vec3) (dPdy :vec3) (offset :vec3)) :out :uvec4)
          (:in ((sampler :sampler-1d) (P :vec2) (dPdx :float) (dPdy :float) (offset :int)) :out :vec4)
          (:in ((sampler :sampler-1d) (P :vec4) (dPdx :float) (dPdy :float) (offset :int)) :out :vec4)
          (:in ((sampler :sampler-1d-shadow) (P :vec4) (dPdx :float) (dPdy :float) (offset :int)) :out :float)
          (:in ((sampler :sampler-2d) (P :vec3) (dPdx :vec2) (dPdy :vec2) (offset :vec2)) :out :vec4)
          (:in ((sampler :sampler-2d) (P :vec4) (dPdx :vec2) (dPdy :vec2) (offset :vec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect) (P :vec3) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect) (P :vec4) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :vec4)
          (:in ((sampler :sampler-2d-rect-shadow) (P :vec4) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :float)
          (:in ((sampler :sampler-2d-shadow) (P :vec4) (dPdx :vec2) (dPdy :vec2) (offset :vec2)) :out :float)
          (:in ((sampler :sampler-3d) (P :vec4) (dPdx :vec3) (dPdy :vec3) (offset :vec3)) :out :vec4)
          (:in ((sampler :usampler-1d) (P :vec2) (dPdx :float) (dPdy :float) (offset :int)) :out :ivec4)
          (:in ((sampler :usampler-1d) (P :vec4) (dPdx :float) (dPdy :float) (offset :int)) :out :ivec4)
          (:in ((sampler :usampler-2d) (P :vec3) (dPdx :vec2) (dPdy :vec2) (offset :vec2)) :out :ivec4)
          (:in ((sampler :usampler-2d) (P :vec4) (dPdx :vec2) (dPdy :vec2) (offset :vec2)) :out :ivec4)
          (:in ((sampler :usampler-2d-rect) (P :vec3) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :usampler-2d-rect) (P :vec4) (dPdx :vec2) (dPdy :vec2) (offset :ivec2)) :out :ivec4)
          (:in ((sampler :usampler-3d) (P :vec4) (dPdx :vec3) (dPdy :vec3) (offset :vec3)) :out :ivec4))
 :transform "textureProjGradOffset(~a, ~a, ~a, ~a, ~a)"
 :context-restriction '((:330)))

;; I think these are all deprecated, YAY!

;; (glsl-multi-defun 
;;  :name 'texture-1D 
;;  '(:in ((sampler :sampler-1d) (coord :float) (bias :float)) :out :int )
;;  :transform "texture1D(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-1D 
;;  '(:in ((sampler :sampler-1d) (coord :float)) :out :int )
;;  :transform "texture1D(~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-1d-proj 
;;  '(:in ((sampler :sampler-1d) (coord :vec2) (bias :float)) :out :int )
;;  :transform "texture1DProj(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-1d-proj 
;;  '(:in ((sampler :sampler-1d) (coord :vec2)) :out :int )
;;  :transform "texture1DProj(~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-1d-proj 
;;  '(:in ((sampler :sampler-1d) (coord :vec4) (bias :float)) :out :int )
;;  :transform "texture1DProj(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-1d-proj 
;;  '(:in ((sampler :sampler-1d) (coord :vec4)) :out :int )
;;  :transform "texture1DProj(~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-1d-lod 
;;  '(:in ((sampler :sampler-1d) (coord :float) (lod :float)) :out :int )
;;  :transform "texture1DLod(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-1d-proj-lod 
;;  '(:in ((sampler :sampler-1d) (coord :vec2) (lod :float)) :out :int )
;;  :transform "texture1DProjLod(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-1d-proj-lod 
;;  '(:in ((sampler :sampler-1d) (coord :vec4) (lod :float)) :out :int )
;;  :transform "texture1DProjLod(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-2D 
;;  '(:in ((sampler :sampler-2d) (coord :vec2) (bias :float)) :out :int )
;;  :transform "texture2D(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-2D 
;;  '(:in ((sampler :sampler-2d) (coord :vec2)) :out :int )
;;  :transform "texture2D(~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-2d-proj 
;;  '(:in ((sampler :sampler-2d) (coord :vec3) (bias :float)) :out :int )
;;  :transform "texture2DProj(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-2d-proj 
;;  '(:in ((sampler :sampler-2d) (coord :vec3)) :out :int )
;;  :transform "texture2DProj(~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-2d-proj 
;;  '(:in ((sampler :sampler-2d) (coord :vec4) (bias :float)) :out :int )
;;  :transform "texture2DProj(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-2d-proj 
;;  '(:in ((sampler :sampler-2d) (coord :vec4)) :out :int )
;;  :transform "texture2DProj(~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-2d-lod 
;;  '(:in ((sampler :sampler-2d) (coord :vec2) (lod :float)) :out :int )
;;  :transform "texture2DLod(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-2d-proj-lod 
;;  '(:in ((sampler :sampler-2d) (coord :vec3) (lod :float)) :out :int )
;;  :transform "texture2DProjLod(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-2d-proj-lod 
;;  '(:in ((sampler :sampler-2d) (coord :vec4) (lod :float)) :out :int )
;;  :transform "texture2DProjLod(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-3D 
;;  '(:in ((sampler :sampler-3d) (coord :vec3) (bias :float)) :out :int )
;;  :transform "texture3D(~a, ~a, ~a)"
;;  :context-restriction '((:330)))p

;; (glsl-multi-defun 
;;  :name 'texture-3D 
;;  '(:in ((sampler :sampler-3d) (coord :vec3)) :out :int )
;;  :transform "texture3D(~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-3d-proj 
;;  '(:in ((sampler :sampler-3d) (coord :vec4) (bias :float)) :out :int )
;;  :transform "texture3DProj(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-3d-proj 
;;  '(:in ((sampler :sampler-3d) (coord :vec4)) :out :int )
;;  :transform "texture3DProj(~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-3d-lod 
;;  '(:in ((sampler :sampler-3d) (coord :vec3) (lod :float)) :out :int )
;;  :transform "texture3DLod(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-3d-proj-lod 
;;  '(:in ((sampler :sampler-3d) (coord :vec4) (lod :float)) :out :int )
;;  :transform "texture3DProjLod(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-cube 
;;  '(:in ((sampler :sampler-cube) (coord :vec3) (bias :float)) :out :int )
;;  :transform "textureCube(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-cube 
;;  '(:in ((sampler :sampler-cube) (coord :vec3)) :out :int )
;;  :transform "textureCube(~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'texture-cube-lod 
;;  '(:in ((sampler :sampler-cube) (coord :vec3) (lod :float)) :out :int )
;;  :transform "textureCubeLod(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'shadow-1D 
;;  '(:in ((sampler :sampler-1d-shadow) (coord :vec3) (bias :float)) :out :int )
;;  :transform "shadow1D(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'shadow-1D 
;;  '(:in ((sampler :sampler-1d-shadow) (coord :vec3)) :out :int )
;;  :transform "shadow1D(~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'shadow-2D 
;;  '(:in ((sampler :sampler-2d-shadow) (coord :vec3) (bias :float)) :out :int )
;;  :transform "shadow2D(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'shadow-2D 
;;  '(:in ((sampler :sampler-2d-shadow) (coord :vec3)) :out :int )
;;  :transform "shadow2D(~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'shadow-1d-proj 
;;  '(:in ((sampler :sampler-1d-shadow) (coord :vec4) (bias :float)) :out :int )
;;  :transform "shadow1DProj(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'shadow-1d-proj 
;;  '(:in ((sampler :sampler-1d-shadow) (coord :vec4)) :out :int )
;;  :transform "shadow1DProj(~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'shadow-2d-proj 
;;  '(:in ((sampler :sampler-2d-shadow) (coord :vec4) (bias :float)) :out :int )
;;  :transform "shadow2DProj(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun p
;;  :name 'shadow-2d-proj 
;;  '(:in ((sampler :sampler-2d-shadow) (coord :vec4)) :out :int )
;;  :transform "shadow2DProj(~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'shadow-1d-lod 
;;  '(:in ((sampler :sampler-1d-shadow) (coord :vec3) (lod :float)) :out :int )
;;  :transform "shadow1DLod(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'shadow-2d-lod 
;;  '(:in ((sampler :sampler-2d-shadow) (coord :vec3) (lod :float)) :out :int )
;;  :transform "shadow2DLod(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'shadow-1d-proj-lod 
;;  '(:in ((sampler :sampler-1d-shadow) (coord :vec4) (lod :float)) :out :int )
;;  :transform "shadow1DProjLod(~a, ~a, ~a)"
;;  :context-restriction '((:330)))

;; (glsl-multi-defun 
;;  :name 'shadow-2d-proj-lod 
;;  '(:in ((sampler :sampler-2d-shadow) (coord :vec4) (lod :float)) :out :int )
;;  :transform "shadow2DProjLod(~a, ~a, ~a)"
;;  :context-restriction '((:330)))
