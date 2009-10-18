;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; indent-tabs-mode: nil -*-
;;;
;;; --- SBCL implementation.
;;;

(in-package :static-vectors)

(declaim (inline fill-foreign-memory))
(defun fill-foreign-memory (pointer length value)
  "Fill LENGTH octets in foreign memory area POINTER with VALUE."
  (declare (sb-ext:muffle-conditions sb-ext:compiler-note))
  (sb-kernel:system-area-ub8-fill value pointer 0 length)
  pointer)

(declaim (inline copy-foreign-memory))
(defun copy-foreign-memory (src-ptr dst-ptr length)
  "Copy LENGTH octets from foreign memory area SRC-PTR to DST-PTR."
  (sb-kernel:system-area-ub8-copy src-ptr 0 dst-ptr 0 length)
  dst-ptr)

(defconstant +array-header-size+
  (* sb-vm:vector-data-offset sb-vm:n-word-bytes))

(declaim (inline vector-widetag-and-n-bits))
(defun vector-widetag-and-n-bits (type)
  (let ((upgraded-type (upgraded-array-element-type type)))
    (case upgraded-type
      ((nil t) (error "~A is not a specializable array element type" type))
      (t       (sb-impl::%vector-widetag-and-n-bits type)))))

(declaim (inline %allocate-static-vector))
(defun %allocate-static-vector (allocation-size widetag length initial-element)
  (let ((memblock (foreign-alloc :char :count allocation-size)))
    (cond
      ((null-pointer-p memblock)
       ;; FIXME: signal proper error condition
       (error 'storage-condition))
      (t
       ;; check for alignment
       (assert (zerop (logand (pointer-address memblock) sb-vm:lowtag-mask)))
       (fill-foreign-memory memblock allocation-size 0)
       (let ((length (sb-vm:fixnumize length)))
         (setf (mem-aref memblock :long 0) widetag
               (mem-aref memblock :long 1) length)
         (fill (sb-kernel:%make-lisp-obj (logior (pointer-address memblock)
                                                 sb-vm:other-pointer-lowtag))
               initial-element))))))

(declaim (inline %allocation-size))
(defun %allocation-size (widetag length n-bits)
  (flet ((string-widetag-p (widetag)
           (or (= widetag sb-vm:simple-base-string-widetag)
               #+sb-unicode
               (= widetag sb-vm:simple-character-string-widetag))))
    (+ (* 2 sb-vm:n-word-bytes
          (ceiling
           (* (if (string-widetag-p widetag)
                    (1+ length)  ; for the final #\Null
                    length)
              n-bits)
           (* 2 sb-vm:n-word-bits)))
       +array-header-size+)))

(defun make-static-vector (length &key (element-type '(unsigned-byte 8))
                           (initial-element 0 initial-element-p))
  "Create a simple vector of length LENGTH and type ELEMENT-TYPE which will
not be moved by the garbage collector. The vector might be allocated in
foreign memory so you must always call FREE-STATIC-VECTOR to free it."
  (declare (sb-ext:muffle-conditions sb-ext:compiler-note)
           (optimize speed))
  (check-type length non-negative-fixnum)
  (multiple-value-bind (widetag n-bits)
      (vector-widetag-and-n-bits element-type)
    (let ((allocation-size
           (%allocation-size widetag length n-bits))
          (actual-initial-element
           (%choose-initial-element element-type initial-element initial-element-p)))
      (%allocate-static-vector allocation-size widetag length actual-initial-element))))

(define-compiler-macro make-static-vector (&whole whole &environment env
                                           length &key (element-type ''(unsigned-byte 8))
                                           (initial-element 0 initial-element-p))
  (cond
    ((constantp element-type env)
     (let ((element-type (eval element-type)))
       (multiple-value-bind (widetag n-bits)
           (vector-widetag-and-n-bits element-type)
         (let ((actual-initial-element
                (if (constantp initial-element env)
                    (%choose-initial-element element-type (eval initial-element) initial-element-p)
                    `(%choose-initial-element ',element-type ,initial-element ,initial-element-p))))
           (if (constantp length env)
               (let ((%length% (eval length)))
                 (check-type %length% non-negative-fixnum)
                 `(sb-ext:truly-the
                   (simple-array ,element-type (,%length%))
                   (%allocate-static-vector ,(%allocation-size widetag %length% n-bits)
                                            ,widetag ,%length% ,actual-initial-element)))
               (with-gensyms (%length%)
                 `(let ((,%length% ,length))
                    (check-type ,%length% non-negative-fixnum)
                    (sb-ext:truly-the
                     (simple-array ,element-type (*))
                     (%allocate-static-vector (%allocation-size ,widetag ,%length% ,n-bits)
                                              ,widetag ,%length% ,actual-initial-element)))))))))
    (t whole)))

(declaim (inline static-vector-address))
(defun static-vector-address (vector)
  "Return a foreign pointer to VECTOR(including its header).
VECTOR must be a vector created by MAKE-STATIC-VECTOR."
  (logandc2 (sb-kernel:get-lisp-obj-address vector)
            sb-vm:lowtag-mask))

(declaim (inline static-vector-pointer))
(defun static-vector-data-pointer (vector)
  "Return a foreign pointer to VECTOR's data.
VECTOR must be a vector created by MAKE-STATIC-VECTOR."
  (make-pointer (+ (static-vector-address vector)
                   +array-header-size+)))

(declaim (inline free-static-vector))
(defun free-static-vector (vector)
  "Free VECTOR, which must be a vector created by MAKE-STATIC-VECTOR."
  (declare (sb-ext:muffle-conditions sb-ext:compiler-note))
  (foreign-free (make-pointer (static-vector-address vector)))
  (values))

(defmacro with-static-vector ((var length &rest args
                               &key (element-type ''(unsigned-byte 8)) (initial-element 0))
                              &body body)
  "Bind PTR-VAR to a static vector of length LENGTH and execute BODY
within its dynamic extent. The vector is freed upon exit."
  (declare (ignore element-type initial-element))
  `(sb-sys:without-interrupts
     (let ((,var (make-static-vector ,length ,@args)))
       (unwind-protect
            (sb-sys:with-interrupts ,@body)
         (when ,var (free-static-vector ,var))
         nil))))
