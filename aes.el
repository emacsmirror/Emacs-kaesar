;;; aes.el --- Encrypt/Decrypt string with password.

;; Author: Masahiro Hayashi <mhayashi1120@gmail.com>
;; Keywords: encrypt decrypt password
;; URL: http://github.com/mhayashi1120/Emacs-aes/raw/master/aes.el
;; Emacs: GNU Emacs 22 or later
;; Version 0.8.0

(defconst aes-version "0.8.0")

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Install:

;; Put this file into load-path'ed directory, and **BYTE COMPILE IT**. 
;; And put the following expression into your .emacs.
;;
;;     (require 'aes)

;;; Usage:

;; * To encode a well encoded string (High level API)
;; `aes-encrypt-string' <-> `aes-decrypt-string'
;;
;; * To encode a binary string (Low level API)
;; `aes-encrypt-unibytes' <-> `aes-decrypt-unibytes'

;;; Sample:

;; * To encrypt my secret
;;   Please ensure that do not forget `clear-string' you want to hide.

;; (defvar my-secret nil)

;; (let ((raw-string "My Secret"))
;;   (setq my-secret (aes-encrypt-string raw-string))
;;   (clear-string raw-string))

;; * To decrypt `my-secret'

;; (aes-decrypt-string my-secret)

;;; TODO:
;; * calculate s-box

;; * about algorithm
;; http://csrc.nist.gov/archive/aes/index.html
;; Rijndael algorithm

;;; Code:

(eval-when-compile
  (require 'cl))

(defcustom aes-algorithm "aes-256-cbc"
  "Cipher algorithm to encrypt a message.
Following algorithms are supported.

aes-256-ecb, aes-192-ecb, aes-128-ecb,
aes-256-cbc, aes-192-cbc, aes-128-cbc
"
  :group 'aes
  :type 'string)

(defvar aes-multibyte-encoding (terminal-coding-system))

(defun aes-encrypt-string (string)
  (aes-encrypt-unibytes
   (encode-coding-string string aes-multibyte-encoding)))

(defun aes-decrypt-string (encrypted)
  (decode-coding-string
   (aes-decrypt-unibytes encrypted)
   aes-multibyte-encoding))

(defun aes-encrypt-unibytes (unibyte-string)
  (when (multibyte-string-p unibyte-string)
    (error "Multibyte string is not supported"))
  (let* ((salt (aes--create-salt))
         (pass (aes--read-passwd "Password: " t)))
    (aes--proc aes-algorithm
      (destructuring-bind (raw-key iv) (aes--bytes-to-key pass salt)
        (let ((key (aes--key-expansion raw-key)))
          (aes--create-encrypted
           aes-algorithm
           (apply
            'aes--unibyte-string
            (append
             (string-to-list aes--openssl-magic-word)
             salt
             (funcall aes--Enc unibyte-string key iv)))))))))

(defun aes-decrypt-unibytes (encrypted)
  (unless (vectorp encrypted)
    (error "Not a encrypted object"))
  (let* ((algorithm (symbol-value (intern "algorithm" encrypted)))
         (raw (symbol-value (intern "encrypted" encrypted))))
    (aes--proc algorithm
      (destructuring-bind (salt encrypted-string) (aes--parse-salt raw)
        (let ((pass (aes--read-passwd "Password: ")))
          (destructuring-bind (raw-key iv) (aes--bytes-to-key pass salt)
            (let ((key (aes--key-expansion raw-key)))
              (apply 
               'aes--unibyte-string
               (funcall aes--Dec encrypted-string key iv)))))))))

(defun aes--read-passwd (prompt &optional confirm)
  (string-to-vector (read-passwd prompt confirm)))

(defun aes--create-encrypted (algorithm string)
  (let ((vec (make-vector 2 nil)))
    (set (intern "algorithm" vec) algorithm)
    (set (intern "encrypted" vec) string)
    vec))

;;
;; Block mode Algorithm 
;;

(defun aes--cbc-encrypt (unibyte-string key iv)
  (loop with rest = unibyte-string
        with state-1 = (aes--unibytes-to-state iv)
        append (let* ((parse (aes--parse-unibytes rest))
                      (state-d0 (aes--cbc-state-xor state-1 (nth 0 parse)))
                      (state-e0 (aes--cipher state-d0 key)))
                 (setq rest (nth 1 parse))
                 (setq state-1 state-e0)
                 (aes--state-to-bytes state-e0))
        while rest))

(defun aes--cbc-decrypt (encrypted-string key iv)
  (aes--check-encrypted-string encrypted-string)
  (loop with rest = encrypted-string
        with state-1 = (aes--unibytes-to-state iv)
        append (let* ((parse (aes--parse-encrypted rest))
                      (state-e (nth 0 parse))
                      ;; Clone state `aes--inv-cipher' have side-effect
                      (state-e0 (aes--state-clone state-e))
                      (state-d0 (aes--cbc-state-xor state-1 (aes--inv-cipher state-e key)))
                      (bytes (aes--state-to-bytes state-d0)))
                 (setq rest (nth 1 parse))
                 (setq state-1 state-e0)
                 (unless rest
                   (setq bytes (aes--check-end-of-decrypted bytes)))
                 (append bytes nil))
        while rest))

(defun aes--cbc-state-xor (state-1 state0)
  (loop for w1 across state-1
        for w2 across state0
        for i from 0
        with state = (make-vector aes--Row nil)
        do (aset state i (aes--word-xor w1 w2))
        finally return state))

;; check End-Of-Block bytes
(defun aes--check-end-of-decrypted (eob-bytes)
  (let* ((pad (car (last eob-bytes)))
         (valid-len (- aes--Block pad)))
    (when (or (> valid-len (length eob-bytes))
              (< valid-len 0))
      (error "Bad decrypt"))
    ;; check non pad byte exists
    ;; o aaa => '(97 97 97 13 13 .... 13)
    ;; x aaa => '(97 97 97 13 10 .... 13)
    (when (remove pad (nthcdr valid-len eob-bytes))
      (error "Bad decrypt"))
    (loop for i from 0 below valid-len
          for u in eob-bytes
          collect u)))

(defun aes--check-encrypted-string (string)
  (unless (= (mod (length string) aes--Block) 0)
    (error "Bad decrypt")))

(defun aes--ecb-encrypt (unibyte-string key &rest dummy)
  (loop with rest = unibyte-string
        append (let* ((parse (aes--parse-unibytes rest))
                      (in-state (nth 0 parse))
                      (out-state (aes--cipher in-state key)))
                 (setq rest (nth 1 parse))
                 (aes--state-to-bytes out-state))
        while rest))

(defun aes--ecb-decrypt (encrypted-string key &rest dummy)
  (aes--check-encrypted-string encrypted-string)
  (loop with rest = encrypted-string
        append (let* ((parse (aes--parse-encrypted rest))
                      (in-state (nth 0 parse))
                      (out-state (aes--inv-cipher in-state key))
                      (bytes (aes--state-to-bytes out-state)))
                 (setq rest (nth 1 parse))
                 (unless rest
                   (setq bytes (aes--check-end-of-decrypted bytes)))
                 (append bytes nil))
        while rest))

;;
;; bit/number operation for Emacs
;;

(defconst aes--emacs-bits 
  (let ((i 0))
    (while (/= (lsh 1 i) 0)
      (setq i (1+ i)))
    (1- i)))

(defun aes--parse-unibytes (unibyte-string)
  (let* ((len (length unibyte-string))
         (sep (min len aes--Block))
         (state (aes--unibytes-to-state (substring unibyte-string 0 sep)))
         (rest (if (< len aes--Block) nil (substring unibyte-string sep))))
    (list state rest)))

(defun aes--parse-encrypted (encrypted-string)
  (let* ((len (length encrypted-string))
         (sep (min len aes--Block))
         (state (aes--unibytes-to-state (substring encrypted-string 0 sep)))
         (rest (if (= len aes--Block) nil (substring encrypted-string sep))))
    (list state rest)))

(defun aes--unibytes-to-state (unibytes)
  (loop for r from 0 below aes--Row
        with state = (make-vector aes--Row nil)
        with len = (length unibytes)
        with suffix-len = (- aes--Block len)
        do (loop for c from 0 below aes--Nb
                 with from = (* aes--Nb r)
                 with word = (make-vector aes--Nb suffix-len)
                 initially (aset state r word)
                 while (< (+ from c) len)
                 ;; word in unibytes
                 ;; if unibytes are before encrypted, state suffixed by length
                 ;; of rest of State
                 do (aset word c (aref unibytes (+ from c))))
        finally return state))

(defun aes--state-to-bytes (state)
  (loop for i from 0 below (* aes--Row aes--Nb)
        collect 
        (let ((r (/ i aes--Row))
              (c (% i aes--Nb)))
          (aref (aref state r) c))))

(defun aes--state-clone (state)
  (vconcat
   (loop for r across state
         collect (vconcat
                  (loop for c across r
                        collect c)))))

(defconst aes--pkcs5-salt-length 8)
(defconst aes--openssl-magic-word "Salted__")

(defun aes--create-salt ()
  (let ((salt (make-vector aes--pkcs5-salt-length nil)))
    (loop for i from 0 below aes--pkcs5-salt-length
          do (aset salt i (random ?\x100)))
    salt))

(defun aes--parse-salt (unibyte-string)
  (let ((regexp (format "^%s\\([\000-\377]\\{%d\\}\\)"
                        aes--openssl-magic-word aes--pkcs5-salt-length)))
    (unless (string-match regexp unibyte-string)
      (error "No salted"))
    (list
     (string-to-vector (match-string 1 unibyte-string))
     (substring unibyte-string (match-end 0)))))

;; Emulate openssl EVP_BytesToKey function
;; return '(key iv)
(defun aes--bytes-to-key (data &optional salt)
  (let ((iv (make-vector aes--IV nil))
        (key (make-vector (* aes--Nk aes--Nb) nil))
        ;;md5 hash size
        (hash (make-vector 16 nil))
        (ii 0)
        (ki 0))
    (loop while (or (< ki (length key))
                    (< ii (length iv)))
          do
          (let (context)
            ;; After first loop
            (when (aref hash 0)
              (setq context (append context hash nil)))
            (setq context (append context data nil))
            (when salt
              (setq context (append context salt nil)))
            (aes--key-digest hash context)
            (let ((i 0))
              (loop for j from ki below (length key)
                    while (< i (length hash))
                    do (progn 
                         (aset key j (aref hash i))
                         (incf i))
                    finally (setq ki j))
              (loop for j from ii below (length iv)
                    while (< i (length hash))
                    do (progn 
                         (aset iv j (aref hash i))
                         (incf i))
                    finally (setq ii j)))))
    (fillarray data nil)
    (list key iv)))

(defun aes--key-digest (hash data)
  (loop for v across (aes--hex-to-vector (md5 (apply 'aes--unibyte-string data)))
        for i from 0
        do (aset hash i v)))

(defun aes--clone-vector (vector)
  (apply 'vector
         (loop for v across vector
               collect v)))

(defun aes--hex-to-vector (hex-string)
  (vconcat
   (loop for i from 0 below (length hex-string) by 2
         collect (string-to-number (substring hex-string i (+ i 2)) 16))))

(if (fboundp 'unibyte-string)
    (defalias 'aes--unibyte-string 'unibyte-string)
  (defun aes--unibyte-string (&rest bytes)
    (concat bytes)))

;;
;; AES Algorithm defined functions
;;

;; 4.1 Addition
(defun aes--add (&rest numbers)
  (apply 'logxor numbers))

;; 4.2 Multiplication
;; 4.2.1 xtime
(defconst aes--xtime-table
  (loop for byte from 0 below ?\x100
        with table = (make-vector ?\x100 nil)
        do (aset table byte 
                 (if (< byte ?\x80)
                     (lsh byte 1)
                   (logand (logxor (lsh byte 1) ?\x11b) ?\xff)))
        finally return table))

(defun aes--xtime (byte)
  (aref aes--xtime-table byte))

(defun aes--multiply (byte1 byte2)
  (aref (aref multiply--cache-table byte1) byte2))


(defconst aes--multiply-table
  (loop for i from 0 to ?\xff
        with table = (make-vector ?\x100 nil)
        do 
        (loop for j from 1 to 7
              with l = (make-vector 8 nil)
              with v = i
              initially (progn
                          (aset table i l)
                          (aset l 0 i))
              do (let ((n (aes--xtime v)))
                   (aset l j n)
                   (setq v n)))
        finally return table))

(defun aes--multiply-0 (byte1 byte2)
  (let ((table (aref aes--multiply-table byte1)))
    (apply 'aes--add
           (loop for i from 0 to 7
                 if (/= (logand byte2 (lsh 1 i)) 0)
                 collect (aref table i)))))

(defconst multiply--cache-table 
  (vconcat
   (loop for b1 from 0 to 255
         collect 
         (vconcat (loop for b2 from 0 to 255
                        collect (aes--multiply-0 b1 b2))))))

;; section 5.2
(defun aes--key-expansion (key)
  (let (res)
    (loop for i from 0 below aes--Nk
          do 
          (setq res (cons  
                     (loop for j from 0 below aes--Nb
                           with w = (make-vector aes--Nb nil)
                           do (aset w j (aref key (+ j (* aes--Nb i))))
                           finally return w)
                     res)))
    (loop for i from aes--Nk below (* aes--Nb (1+ aes--Nr))
          do (let ((temp (car res)))
               (cond
                ((= (mod i aes--Nk) 0)
                 (setq temp (aes--word-xor 
                             (aes--sub-word
                              (aes--rot-word temp))
                             ;; `i' is start from 1
                             (aref aes--Rcon (1- (/ i aes--Nk))))))
                ((and (> aes--Nk 6)
                      (= (mod i aes--Nk) 4))
                 (setq temp (aes--sub-word temp))))
               (setq res (cons
                          (aes--word-xor 
                           (nth (1- aes--Nk) res)
                           temp)
                          res))))
    (nreverse res)))

(defun aes--rot-word (word)
  (vconcat (aes--rot (append word nil) 1)))

(defun aes--sub-word (word)
  (loop for b across word
        for i from 0
        with w = (make-vector aes--Nb nil)
        do (aset w i (aref aes--S-box b))
        finally return w))

;; section 5.1
(defun aes--cipher (state key)
  (aes--add-round-key state (aes--round-key key 0))
  (loop for round from 1 to (1- aes--Nr)
        do (progn
             (aes--sub-bytes state)
             (aes--shift-rows state)
             (aes--mix-columns state)
             (aes--add-round-key 
              state 
              (aes--round-key key (* round aes--Nb)))))
  (aes--sub-bytes state)
  (aes--shift-rows state)
  (aes--add-round-key state 
                      (aes--round-key key (* aes--Nr aes--Nb)))
  state)

;; section 5.3 
(defun aes--inv-cipher (state key)
  (aes--add-round-key state 
                      (aes--round-key key (* aes--Nr aes--Nb)))
  (loop for round downfrom (1- aes--Nr) to 1
        do (progn
             (aes--inv-shift-rows state)
             (aes--inv-sub-bytes state)
             (aes--add-round-key 
              state 
              (aes--round-key key (* round aes--Nb)))
             (aes--inv-mix-columns state)))
  (aes--inv-shift-rows state)
  (aes--inv-sub-bytes state)
  (aes--add-round-key state (aes--round-key key 0))
  state)

;; section 5.1.4
(defun aes--add-round-key (state round-key)
  (loop for row across state
        for r from 0
        for k across round-key
        do (aset state r (aes--word-xor row k)))
  state)

(defun aes--round-key (key n)
  (loop repeat aes--Row
        for ki from n
        for ri from 0
        with rk = (make-vector aes--Nb nil)
        do (aset rk ri (nth ki key))
        finally return rk))

;; section 5.1.3
(defun aes--mix-columns (state)
  (loop for row from 0 below aes--Row
        do (aes--mix-column state row '(?\x2 ?\x3 ?\x1 ?\x1)))
  state)

;; section 5.3.3
(defun aes--inv-mix-columns (state)
  (loop for row from 0 below aes--Row
        do (aes--mix-column state row '(?\xe ?\xb ?\xd ?\x9)))
  state)

(defun aes--mix-column (state row rotate)
  (let ((columns (loop for i from 0 below aes--Nb
                       collect
                       (loop for a in (aes--rot rotate (- i))
                             for c across (aref state row)
                             with acc = 0
                             do (setq acc (aes--add (aes--multiply a c) acc))
                             finally return acc))))
    (loop for c in columns
          for i from 0
          with vec = (aref state row)
          do (aset vec i c))
    state))

(defvar aes--Rcon
  [[?\x01 0 0 0] [?\x02 0 0 0] [?\x04 0 0 0] [?\x08 0 0 0] [?\x10 0 0 0]
   [?\x20 0 0 0] [?\x40 0 0 0] [?\x80 0 0 0] [?\x1B 0 0 0] [?\x36 0 0 0]])

;; section 5.1.2
(defun aes--shift-rows (state)
  ;; ignore first row
  (loop for row from 1 below aes--Row
        do
        (aes--shift-row state row row))
  state)

;; section 5.3.1
(defun aes--inv-shift-rows (state)
  ;; ignore first row
  (loop for row from 1 below aes--Row
        do
        (aes--shift-row state row (- aes--Nb row)))
  state)

(defun aes--shift-row (state row count)
  (let ((new-rows (loop for col from 0 below aes--Nb
                        collect 
                        (aref (aref state (mod (+ col count) aes--Nb)) row))))
    (loop for col from 0 below aes--Nb
          for new-row in new-rows
          do
          (aset (aref state col) row new-row))))


;; section 5.1.1
(defconst aes--S-box
  [
   ?\x63 ?\x7c ?\x77 ?\x7b ?\xf2 ?\x6b ?\x6f ?\xc5 ?\x30 ?\x01 ?\x67 ?\x2b ?\xfe ?\xd7 ?\xab ?\x76
   ?\xca ?\x82 ?\xc9 ?\x7d ?\xfa ?\x59 ?\x47 ?\xf0 ?\xad ?\xd4 ?\xa2 ?\xaf ?\x9c ?\xa4 ?\x72 ?\xc0
   ?\xb7 ?\xfd ?\x93 ?\x26 ?\x36 ?\x3f ?\xf7 ?\xcc ?\x34 ?\xa5 ?\xe5 ?\xf1 ?\x71 ?\xd8 ?\x31 ?\x15
   ?\x04 ?\xc7 ?\x23 ?\xc3 ?\x18 ?\x96 ?\x05 ?\x9a ?\x07 ?\x12 ?\x80 ?\xe2 ?\xeb ?\x27 ?\xb2 ?\x75
   ?\x09 ?\x83 ?\x2c ?\x1a ?\x1b ?\x6e ?\x5a ?\xa0 ?\x52 ?\x3b ?\xd6 ?\xb3 ?\x29 ?\xe3 ?\x2f ?\x84
   ?\x53 ?\xd1 ?\x00 ?\xed ?\x20 ?\xfc ?\xb1 ?\x5b ?\x6a ?\xcb ?\xbe ?\x39 ?\x4a ?\x4c ?\x58 ?\xcf
   ?\xd0 ?\xef ?\xaa ?\xfb ?\x43 ?\x4d ?\x33 ?\x85 ?\x45 ?\xf9 ?\x02 ?\x7f ?\x50 ?\x3c ?\x9f ?\xa8
   ?\x51 ?\xa3 ?\x40 ?\x8f ?\x92 ?\x9d ?\x38 ?\xf5 ?\xbc ?\xb6 ?\xda ?\x21 ?\x10 ?\xff ?\xf3 ?\xd2
   ?\xcd ?\x0c ?\x13 ?\xec ?\x5f ?\x97 ?\x44 ?\x17 ?\xc4 ?\xa7 ?\x7e ?\x3d ?\x64 ?\x5d ?\x19 ?\x73
   ?\x60 ?\x81 ?\x4f ?\xdc ?\x22 ?\x2a ?\x90 ?\x88 ?\x46 ?\xee ?\xb8 ?\x14 ?\xde ?\x5e ?\x0b ?\xdb
   ?\xe0 ?\x32 ?\x3a ?\x0a ?\x49 ?\x06 ?\x24 ?\x5c ?\xc2 ?\xd3 ?\xac ?\x62 ?\x91 ?\x95 ?\xe4 ?\x79
   ?\xe7 ?\xc8 ?\x37 ?\x6d ?\x8d ?\xd5 ?\x4e ?\xa9 ?\x6c ?\x56 ?\xf4 ?\xea ?\x65 ?\x7a ?\xae ?\x08
   ?\xba ?\x78 ?\x25 ?\x2e ?\x1c ?\xa6 ?\xb4 ?\xc6 ?\xe8 ?\xdd ?\x74 ?\x1f ?\x4b ?\xbd ?\x8b ?\x8a
   ?\x70 ?\x3e ?\xb5 ?\x66 ?\x48 ?\x03 ?\xf6 ?\x0e ?\x61 ?\x35 ?\x57 ?\xb9 ?\x86 ?\xc1 ?\x1d ?\x9e
   ?\xe1 ?\xf8 ?\x98 ?\x11 ?\x69 ?\xd9 ?\x8e ?\x94 ?\x9b ?\x1e ?\x87 ?\xe9 ?\xce ?\x55 ?\x28 ?\xdf
   ?\x8c ?\xa1 ?\x89 ?\x0d ?\xbf ?\xe6 ?\x42 ?\x68 ?\x41 ?\x99 ?\x2d ?\x0f ?\xb0 ?\x54 ?\xbb ?\x16
   ])

(defun aes--sub-bytes (state)
  (loop for w across state
        do (loop for b across w
                 for c from 0
                 do (aset w c (aref aes--S-box b))))
  state)

;; section 5.3.2
(defconst aes--inv-S-box
  (loop for s across aes--S-box
        for i from 0
        with inv = (make-vector ?\x100 nil)
        do (aset inv s i)
        finally return inv))

(defun aes--inv-sub-bytes (state)
  (loop for w across state
        do (loop for b across w
                 for c from 0
                 do (aset w c (aref aes--inv-S-box b))))
  state)

;; section 5
;; AES-128: Nk 4 Nb 4 Nr 10
;; AES-192: Nk 6 Nb 4 Nr 12
;; AES-256: Nk 8 Nb 4 Nr 14
(defconst aes--cipher-algorithm-alist
  '(
    (aes-128 4 4 10)
    (aes-192 6 4 12)
    (aes-256 8 4 14)
    ))

(defconst aes--block-algorithm-alist
  '(
    (ecb aes--ecb-encrypt aes--ecb-decrypt 0)
    (cbc aes--cbc-encrypt aes--cbc-decrypt aes--Block)
    ))

;; section 6.3
;; Block size
(defvar aes--Nb 4)

;; section 6.3
;; Key length
(defvar aes--Nk)

;; section 6.3
;; Number of rounds
(defvar aes--Nr)

(defvar aes--Enc)
(defvar aes--Dec)

;; count of row in State
(defconst aes--Row 4)
;; size of State
(defvar aes--Block)
;; size of IV (Initial Vector)
(defvar aes--IV)

(defun aes--parse-algorithm (name)
  (unless (string-match "^\\(aes-\\(?:128\\|192\\|256\\)\\)-\\(ecb\\|cbc\\)$" name)
    (error "%s is not supported" name))
  (list (intern (match-string 1 name)) 
        (intern (match-string 2 name))))

(defmacro aes--cipher-algorithm (algorithm &rest form)
  (declare (indent 1))
  (let ((cell (gensym)))
    `(let ((,cell (assq ,algorithm aes--cipher-algorithm-alist)))
       (unless ,cell
         (error "%s is not supported" ,algorithm))
       (let* ((aes--Nk (nth 1 ,cell))
              (aes--Nb (nth 2 ,cell))
              (aes--Nr (nth 3 ,cell))
              (aes--Block (* aes--Nb aes--Row)))
         ,@form))))

(defmacro aes--block-algorithm (algorithm &rest form)
  (declare (indent 1))
  (let ((cell (gensym)))
    `(let ((,cell (assq ,algorithm aes--block-algorithm-alist)))
       (unless ,cell
         (error "%s is not supported" ,algorithm))
       (let* ((aes--Enc (nth 1 ,cell))
              (aes--Dec (nth 2 ,cell))
              (aes--IV (eval (nth 3 ,cell))))
         ,@form))))

(defmacro aes--proc (algorithm &rest form)
  (declare (indent 1))
  (let ((cipher (gensym))
        (block-mode (gensym)))
    `(destructuring-bind (cipher block) (aes--parse-algorithm ,algorithm)
       (aes--cipher-algorithm cipher
         (aes--block-algorithm block
           ,@form)))))

(defun aes--word-xor (word1 word2)
  (loop for b1 across word1
        for b2 across word2
        for i from 0
        with w = (make-vector aes--Nb nil)
        do (aset w i (logxor b1 b2))
        finally return w))

(defun aes--rot (list count)
  (let ((len (length list)))
    (loop for i from 0 below len
          collect (nth (mod (+ i count) len) list))))

(provide 'aes)

;;; aes.el ends here
