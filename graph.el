;;; graph.el --- Draw directed graphs in ascii

;; Copyright (C) 2017 by David ZUBER

;; Author: David ZUBER <zuber.david@gmx.de>
;; URL: https://github.com/storax/graph.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "25.2") (s "1.11.0") (dash "2.13.0"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; A graph layout library for Emacs Lisp.
;; The algorithm is a port from <https://github.com/drcode/vijual>,
;; a Clojure library by Conrad Barski, who deserves most of the credits.

;;; Code:
(require 's)
(require 'seq)
(require 'dash)

(eval-when-compile (require 'cl-lib))
(eval-when-compile (require 'cl))

(cl-defstruct graph-shape
  x y width height type text dir on-top)

(cl-defstruct graph-treen
  id x y width height text wrapped-text line-right line-left line-y line-ypos leaf parent parent-line-y children)

(defmacro let-shape (binding shape &rest body)
  "Bind the slots in BINDING to the values in SHAPE and execute BODY.

For example, this code:

  (let-shape (x y) shape
     (message \"%s\ %s\" x y))

expands to:

  (let ((x (graph-shape-x shape))
        (y (graph-shape-y shape)))
    (message \"%s %s\" x y))"
  (declare (indent defun))
  `(let ((shape ,shape))
     (let ,(mapcar (lambda (x) `(,x (cl-struct-slot-value 'graph-shape ',x shape))) binding)
       ,@body)))

(defmacro let-treen (binding treen &rest body)
  "Bind the slots in BINDING to the values in TREEN and execute BODY.

For example, this code:

  (let-treen (x y) treenode
     (message \"%s\ %s\" x y))

expands to:

  (let ((x (graph-treen-x treenode))
        (y (graph-treen-y treenode)))
    (message \"%s %s\" x y))"
  (declare (indent defun))
  `(let ((treen ,treen))
     (let ,(mapcar (lambda (x) `(,x (cl-struct-slot-value 'graph-treen ',x treen))) binding)
       ,@body)))

(defun graph-half (x)
  "Devide X by two."
  (/ x 2.0))

(defun graph-fill (c &optional n)
  "Return a string with the character C repeated N times."
  (let ((n (max 0 (or n 1))))
    (make-string n c)))

(defun graph-integer-shapes (shapes)
  "Take a sequence of SHAPES and floor all the dimensions for ASCII rendering.

See `graph-shape'."
  (mapcar (lambda (shape)
            (let-shape (x y width height type) shape
              (let ((nu-x (floor x))
                    (nu-y (floor y))
                    (newitem (copy-graph-shape shape)))
                (setf (graph-shape-x newitem) nu-x
                      (graph-shape-y newitem) nu-y
                      (graph-shape-width newitem) (- (floor (+ x width)) nu-x)
                      (graph-shape-height newitem) (- (floor (+ y height)) nu-y))
                newitem)))
          shapes))


(defun graph-rect-relation (ypos y height)
  "Calculate whether a rectangle intersects a YPOS.

Y is the y position of the rectangle.
HEIGHT is the height of the rectangle.

Returns 'on, 'in or 'nil."
  (let ((bottom (- (+ y height) 1)))
    (cond ((or (= ypos y) (= ypos bottom)) 'on)
          ((and (> ypos y) (< ypos bottom)) 'in))))

(defun graph-shapes-height (shapes)
  "Return the maxium y value that is covered by the given SHAPES."
  (apply 'max
         (mapcar (lambda (shape) (let-shape (y height) shape (+ y height)))
                 shapes)))

(defun graph-shapes-width (shapes)
  "Return the maximum x value that is covered by the given SHAPES."
  (apply 'max
         (mapcar (lambda (shape) (let-shape (x width) shape (+ x width)))
                 shapes)))

(defun graph-iter-height (shapes)
  "Iterate over all y values for the height of the given SHAPES.

Starts at 0."
  (number-sequence 0 (- (graph-shapes-height shapes) 1)))

(defun graph-filter-shapes-at-ypos (shapes ypos)
  "Return the SHAPES that are visible at YPOS."
  (--filter (let-shape (y height) it (graph-rect-relation ypos y height)) shapes))

(defun graph-x-sort-shapes (shapes)
  "Sort the given SHAPES.

Shapes that start at a lower x value come first.
If x value is the same the narrower shape takes precedence.
If they are the same width the higher shape takes precedence."
  (sort (copy-sequence shapes)
        (lambda (a b)
          (let ((ax (graph-shape-x a))
                (bx (graph-shape-x b))
                (aw (graph-shape-width a))
                (bw (graph-shape-width b))
                (ah (graph-shape-height a))
                (bh (graph-shape-height b)))
            (or (< ax bx)
                (and (= ax bx) (< aw bw))
                (and (= ax bx) (= aw bw) (> ah bh)))))))

(defun graph-draw-shapes (shapes)
  "Render a list of SHAPES into text.

The two current shape types are 'rect, which represent nodes and
lines between nodes (simply rectangles of minimal width).
The arrow heads are represented as type 'arrow."
  (let ((drawn ""))
    (dolist (ypos (graph-iter-height shapes))
      (let* ((xcur 0)
             (sorted-shapes (graph-x-sort-shapes (graph-filter-shapes-at-ypos shapes ypos)))
             (rest-shapes sorted-shapes))
        (while rest-shapes
          (let ((result (graph-draw-shapes-pos ypos xcur rest-shapes)))
            (setq xcur (cdr (assoc 'xcur result))
                  rest-shapes (cdr (assoc 'shapes result))
                  drawn (concat drawn (cdr (assoc 'drawn result)))))))
      (setq drawn (concat drawn "\n")))
       drawn))

(defun graph-new-xcur (oldx first-x drawn)
  "Return a new xcur value.

OLDX is the current x value.
FIRST-X is the x value of the first shape that is currently drawn.
DRAWN is the string that we got so far.
Returns the max of OLDX and (FIRST-X + (length DRAWN))."
  (max (+ first-x (length drawn)) oldx))

(defun graph-crop-already-drawn (xcur x s)
  "Return a string starting at xcur.

XCUR is the current x cursor possition.
X is the x position of the shape we are drawing.
If X is smaller than XCUR we have to drop that part
because we already drawn over that area.
Else we just return S."
  (if (< x xcur)
      (cl-subseq s (min (length s) (- xcur x)))
    s))

(defun graph-get-next-shapes-to-draw (overlapping shape more)
  "Return the next shapes to draw.

OVERLAPPING is a boolean if shape is currently overlapping
with the first of more.
SHAPE is the current shape that is drawn.
MORE is the rest of the shapes."
  (if overlapping
      (append (list (car more) shape) (cdr more))
    more))

(defun graph-draw-border (type dir width)
  "Draw the border of a shape.

Shape has the given TYPE, DIR and WIDTH."
  (concat
   (cond ((eq 'arrow type)
          (or (cdr (assoc dir '((right . ">")
                                (left . "<")
                                (up . "^")
                                (down . "V"))))
              "*"))
         ((eq 'cap type)
          (cdr (assoc dir '((right . "-")
                            (left . "-")
                            (up . "|")
                            (down . "|")))))
         (t "+"))
   (graph-fill ?- (- width 2))
   (when (> width 1)
     "+")))

(defun graph-draw-body-line (ypos y width text)
  "Draw the body of a shape for a given YPOS.

Y is the y position of the shape.
WIDTH is the width of the shape.
TEXT is the text of the shape."
  (concat
   "|"
   (when (> width 1)
     (let* ((index (- ypos y 1))
            (s (if (>= index (length text))
                   ""
                 (elt text index))))
       (concat s (graph-fill ?\s (- width (length s) 2)) "|")))))

(defun graph-draw-at-ypos (ypos shape)
  "Draw at YPOS the given SHAPE."
  (let-shape (dir type width height y text) shape
    (if (equal 'on (graph-rect-relation ypos y height))
        (graph-draw-border type dir width)
      (graph-draw-body-line ypos y width text))))

(defun graph-get-overlapping-text (s x width on-top shapes)
  "Calculate the overlapping text.

S is the text.
X is the x position of the shape.
WIDTH is the width of the shape.
If non-nil, the shape is ON-TOP.
SHAPES are the other shapes that we have to check for overlapping."
  (or
   (dolist (shape shapes)
    (let ((x2 (graph-shape-x shape))
          (width2 (graph-shape-width shape))
          (on-top2 (graph-shape-on-top shape)))
      (when (<= width2 (+ x width))
        (when (and (<= (+ x2 width2) (+ x width)) (or (not on-top) on-top2))
          (return (list (< (+ x2 width2) (+ x width)) (substring s 0 (min (length s) (- x2 x)))))))))
   (list nil s)))

(defun graph-draw-shapes-pos (ypos xcur shapes)
  "Return the text and the next x position to draw.

YPOS is the current line to render.
XCUR is the current x position to render.
SHAPES are the shapes torender.

Returns an alist with 'xcur, 'shapes, and 'drawn as keys."
  (let* (drawn
         (shape (car shapes))
         (more (cdr shapes)))
    (let-shape (x y width text dir on-top) shape
      (when (<= xcur x) ; draw spaces until the start of the first shape
        (setq drawn (concat drawn (graph-fill ?\s (- x xcur)))))
      (let* ((s (graph-draw-at-ypos ypos shape))
             (overlapping-result (graph-get-overlapping-text s x width on-top more))
             (overlapping (car overlapping-result))
             (s (cadr overlapping-result)))
        (list (cons 'xcur (graph-new-xcur xcur x s))
              (cons 'shapes (graph-get-next-shapes-to-draw overlapping shape more))
              (cons 'drawn (concat drawn (graph-crop-already-drawn xcur x s))))))))

(defun graph-numbered (lst)
  "Enumerate the given LST."
  (let ((counter -1))
    (mapcar (lambda (elem)
              (setq counter (+ counter 1))
              (cons counter elem)) lst)))

(defun graph-label-text (text)
  "Return a text string representing the TEXT for the item.

It handles the special case of symbols, so that 'oak-tree ==> 'oak tree'."
  (if (symbolp text)
      (s-replace "-" " " (symbol-name text))
    text))

(defun graph-center (lines width height)
  "Center the given LINES.

WIDTH and HEIGHT are the dimensions of the shape."
  (let ((n (length lines))
        (lines (--map (concat (make-string (floor (graph-half (- width (length it)))) ?\s) it)
                       lines)))
    (if (< n height)
        (append (cl-loop repeat (graph-half (- height n)) collect "") lines)
      lines)))

(defun graph-positions (pred coll)
  "Return a sequence with the positions at which PRED is t for items in COLL."
  (cl-loop for x to (- (length coll) 1) when (funcall pred (elt coll x)) collect x))

(defun graph-wrap (text width)
  "Optimally wrap TEXT to fit within a given WIDTH, given a monospace font."
  (mapcar
   'concat
   (let (lines)
     (while (> (length text) 0)
       (let* ((mw (min width (length text)))
              (spc (graph-positions (lambda (x) (equal ?\s x)) (substring text 0 mw))))
         (if spc
             (if (= 0 (car (last spc)))
                 (setq text (substring text 1))
               (progn
                 (setq lines (nconc lines (cons (substring text 0 (car (last spc))) nil))
                       text (substring text (+ 1 (car (last spc)))))))
           (progn
             (setq lines (nconc lines (cons (substring text 0 mw) nil))
                   text (substring text mw))))))
     lines)))

(defun graph-horizontal (dir)
  "Return the given DIR if it's horizontal."
  (car (memq dir '(right left))))

(defun graph-vertical (dir)
  "Return the given DIR if it's horizontal."
  (car (memq dir '(up down))))

;;Scan Functions
;; A "scan" is a run-length-encoded list of heights that s used to calculate packing of tree and graphs.
;; An example scan would be [[0 5] [7 10]] which would mean
;; "The height is 5 for an x between 0 (inclusive) and 7 (exclusive).
;; The height is 10 for any x greater than or equal to 7."
(defun graph--scan-add (scan cury xend)
  "Add a pair to the given SCAN.

Scan is a list of (x y) pairs.
CURY is the potential y position to add.
XEND is the potential x position to add."
  (if scan
      (let* ((a (car scan))
             (ax (car a))
             (ay (cadr a))
             (d (cdr scan)))
        (if (<= ax xend)
            (graph--scan-add d ay xend)
          (cons (list xend cury) scan)))
    (list (list xend cury))))

(defun graph--scan-advance (scan cury x y xend)
  (if scan
      (let* ((a (car scan))
             (ax (car a))
             (ay (cadr a))
             (d (cdr scan)))
        (if (> x ax)
            (cons a (graph--scan-advance d ay x y xend))
          (cons (list x y) (graph--scan-add scan cury xend))))
    (list (list x y) (list xend cury))))

(defun graph-scan-add (scan x y wid)
  "Add a new height bar at x with a width of wid and a height of y."
  (let ((xend (+ x wid)))
    (graph--scan-advance scan nil x y xend)))

(defun graph-scan-lowest-y (scan x width)
  "Find in SCAN the lowest y that is available at X with the given WIDTH.

THe line should not intersec with the scan."
  (let (cury besty)
    (or (cl-loop
        while scan do
        (let ((ax (caar scan))
              (ay (cadar scan))
              (d (cdr scan)))
          (cond
           ((<= (+ x width) ax)
            (if besty
                (return (max besty cury))
              (return cury)))
           ((< x ax)
            (setq scan d
                  besty (if besty
                            (max besty ay cury)
                          (if cury
                              (max ay cury)
                            ay))
                  cury ay))
           (t (setq scan d
                    cury ay)))))
        (if besty
            (max besty cury)
          cury))))

;;This code is specific to ascii rendering

(defvar graph-ascii-wrap-threshold 10
  "During ascii rendering, text in boxes wrap after this many characters.")

(defun graph-wrap-fn (text &optional width height)
  "The default wrap functions to wrap the given TEXT to fit in WIDTH and HEIGHT."
  (if (not width)
      (--map (concat " " it) (graph-wrap text graph-ascii-wrap-threshold))
    (--map (concat " " it)
           (graph-center (graph-wrap text (max 1 (- width 4)))
                         (max 1 (- width 4))
                         (- height 3)))))

(defvar graph-node-padding 1
  "Padding between nodes.")

(defvar graph-row-padding 8
  "Padding between rows.")

(defvar graph-line-wid 1
  "Line width.")

(defvar graph-line-padding 1
  "Line padding.")

(defun graph-height-fn (text)
  "Height of a box given a TEXT."
  (+ (length (graph-wrap text graph-ascii-wrap-threshold)) 2))

(defun graph-width-fn (text)
  "Width of a box given a TEXT."
  (+ (min (length text) graph-ascii-wrap-threshold) 4))

;;Functions specific to tree drawing

(defun graph--tree-to-shapes (tree)
  "Convert a full layed-out TREE into a bunch of shapes to be sent to the rendering backend."
  (apply 'append
         (mapcar
          (lambda (node)
            (let-treen (x y width height text line-left line-right line-ypos leaf parent-line-y) node
              (append
               (when parent-line-y
                 (list (make-graph-shape :type 'rect
                                         :x (+ x (graph-half width) (- (graph-half graph-line-wid)))
                                         :y parent-line-y
                                         :width graph-line-wid
                                         :height (+ 1 (- y parent-line-y)))))
               (list (make-graph-shape :type 'rect :text (graph-wrap-fn text width height)
                                       :x x :y y :width width :height height))
               (unless leaf
                 (list (make-graph-shape :type 'rect
                                         :x line-left :y line-ypos
                                         :width (- line-right line-left)
                                         :height graph-line-wid)
                       (make-graph-shape :type 'rect
                                         :x (+ x (graph-half width) (- (graph-half graph-line-wid)))
                                         :y (- (+ y height) 1)
                                         :width graph-line-wid
                                         :height (+ (- line-ypos y height) 2)))))))
          tree)))

(defun graph-make-rows (tree)
  "Take a TREE and convert it into rows.

This is needed since items in the same row and their widths will affect the spacing and layout of items."
  (when tree
    (cons (mapcar (lambda (node)
                    (let-treen (text id parent children) node
                      (make-graph-treen :text text :id id :parent parent :leaf (seq-empty-p children))))
                  tree)
          (graph-make-rows
           (seq-mapcat (lambda (node)
                         (let-treen (id children) node
                           (mapcar (lambda (child)
                                     (let ((newc (copy-graph-treen child)))
                                       (setf (graph-treen-parent newc) id)
                                       newc))
                                   children)))
                       tree)))))

(defun graph-wrap-text (rows)
  "Calculate the wrapped text of each tree item in ROWS and their height.

The height depends on how the text is broken into lines."
  (mapcar
   (lambda (row)
     (mapcar (lambda (item)
               (let ((text (graph-treen-text item))
                     (newitem (copy-graph-treen item)))
                 (setf (graph-treen-wrapped-text newitem) (graph-wrap-fn text)
                       (graph-treen-height newitem) (graph-height-fn text))
                 newitem))
             row))
   rows))

(defun graph-row-pos (row y)
  "Calculate preliminary x positions for nodes in ROW.

Y is unused.
This will be refined later by the calculations from `graph-space' and `graph-space-row'."
  (let ((x 0))
    (mapcar
     (lambda (item)
       (let* ((text (graph-treen-text item))
              (w (graph-width-fn text))
              (newitem (copy-graph-treen item))
              (oldx x))
         (setq x (+ oldx w graph-node-padding))
         (setf (graph-treen-x newitem) oldx
               (graph-treen-width newitem) w
               (graph-treen-height newitem) (graph-height-fn text))
         newitem))
     row)))

(defun graph-parent-p (child parent)
  "Return t if CHILD's parent is PARENT."
  (let ((cp (graph-treen-parent child))
        (pid (graph-treen-id parent)))
    (and cp pid (equal cp pid))))

(defun graph-child-p (parent child)
  "Return t if PARENT has the given CHILD."
  (graph-parent-p child parent))

(defun graph-space-row (fun total-width target-row row remaining)
  "Calculate the x positions of tree nodes.

All calculations start from the longest row in the tree.
This function is then used to position nodes upwards
or downwards from the longest row.
Each row is positioned relative a 'target row',
which is the neighboring row nearest to the longest row.

FUN is either `graph-child-p' or `graph-parent-p'."
  (let ((curx 0))
    (mapcar
     (lambda (item)
       (let-treen (width id) item
         (let* ((newitem (copy-graph-treen item))
                (children (seq-filter (lambda (row) (funcall fun row item)) target-row))
                (child-pos (mapcar (lambda (item)
                                     (+ (graph-treen-x item) (graph-half (graph-treen-width item))))
                                   children))
                (nu-remaining (- remaining width graph-node-padding))
                (nu-x (if child-pos
                          (let* ((child (car children))
                                 (siblings (seq-filter (lambda (item) (funcall fun child item)) row))
                                 (left-scoot (if (and (< 1 (length siblings)) (= (graph-treen-id (car siblings)) id))
                                                 (graph-half (- (apply '+ (mapcar (lambda (item)
                                                                                    (+ (graph-treen-width item) graph-node-padding))
                                                                                  siblings))
                                                                graph-node-padding (graph-treen-width child)))
                                               0))
                                 (k (- (graph-half (+ (car child-pos) (car (last child-pos)))) (graph-half width) left-scoot))
                                 (nu-right (+ k width graph-node-padding)))
                            (if (< k curx)
                                curx
                              (if (< (- total-width nu-right) nu-remaining)
                                  (- total-width nu-remaining graph-node-padding width)
                                k)))
                        curx)))
           (setq remaining nu-remaining
                 curx (+ nu-x width graph-node-padding))
           (setf (graph-treen-x newitem) nu-x)
           newitem)))
     row)))

(defun graph-space (fun total-width target-row rest)
  "Use space-row for a list of rows."
  (when rest
    (let* ((curx 0)
           (row (caar rest))
           (remaining (cadar rest))
           (more (cdr rest))
           (nu-row (graph-space-row fun total-width target-row row remaining)))
      (cons nu-row (graph-space fun total-width nu-row more)))))

(defun graph-bounds (node)
  "Calculate the boundary of the given NODE."
  (let-treen (x width) node
    (+ x (graph-half width))))

(defun graph-horz-lines (rows)
  "Calculate the left and right extents of the horizontal lines below nodes in ROWS that lead to their children."
  (cl-mapcar (lambda (cur next)
               (mapcar (lambda (cur)
                         (let* ((id (graph-treen-id cur))
                                (ranges (cons (graph-bounds cur)
                                              (cl-loop for chi in next when
                                                       (= id (graph-treen-parent chi))
                                                       collect (graph-bounds chi))))
                                (newcur (copy-graph-treen cur)))
                           (setf (graph-treen-line-left newcur) (- (apply 'min ranges) (graph-half graph-line-wid))
                                 (graph-treen-line-right newcur) (+ (apply 'max ranges) (graph-half graph-line-wid)))
                           newcur))
                       cur))
             rows
             (append (cdr rows) (list (list)))))

(defun graph-level-lines (lined)
  "Stack horizontal lines of the LINED shapes vertically in an optimal fashion.

Nodes should be able to connect to their children in a tree with the least amount of inbetween space."
  (mapcar
   (lambda (row)
     (let ((group-right 0)
           (line-y 0))
       (mapcar
        (lambda (item)
          (let-treen (leaf line-left line-right x width) item
            (let ((newitem (copy-graph-treen item)))
              (cond (leaf item)
                    ((and group-right (> (+ group-right graph-line-wid) line-left))
                     (setq line-y (if (<= (+ x (graph-half width)) (+ group-right graph-line-padding))
                                      (- line-y 1)
                                    (+ line-y 1))))
                    (t (setq line-y 0)))
              (setq group-right (max line-right group-right))
              (setf (graph-treen-line-y newitem) line-y)
              newitem)))
        row)))
   lined))

(defun graph-lev-children (levlines)
  "Update children with the level of the horizontal line of their parents."
  (cl-mapcar
   (lambda (cur par)
     (mapcar (lambda (item)
               (let* ((newitem (copy-graph-treen item))
                      (parent (graph-treen-parent item))
                      (k (car (seq-filter (lambda (other) (= (graph-treen-id other) parent)) par)))
                      (liney (when k (graph-treen-line-ypos k))))
                 (setf (graph-treen-parent-line-y newitem) liney)
                 newitem))
             cur))
   levlines
   (cons (list) levlines)))

(defun graph-place-boxes (scan acc row)
  "Place boxes as high as possible during tree packing."
  (cl-loop while t do
    (if row
        (let* ((item (car row))
               (newitem (copy-graph-treen item))
               (r (cdr row)))
          (let-treen (x width height) item
            (let ((y (graph-scan-lowest-y scan x width)))
              (setf (graph-treen-y newitem) y)
              (setq scan (graph-scan-add scan x (+ y height graph-line-padding) width)
                    acc (cons newitem acc)
                    row r))))
      (return (list (reverse acc) scan)))))

(defun graph-place-lines (scan acc row)
  "Place lines as hight as possible during tree packing."
  (cl-loop while t do
    (if row
        (let* ((item (car row))
               (line-left (graph-treen-line-left item))
               (line-right (graph-treen-line-right item))
               (leaf (graph-treen-leaf item))
               (r (cdr row))
               (line-width (- line-right line-left))
               (cury (graph-scan-lowest-y scan line-left line-width)))
          (if leaf
              (setq acc (cons item acc)
                    row r)
            (let ((newitem (copy-graph-treen item)))
              (setf (graph-treen-line-ypos newitem) cury)
              (setq scan (graph-scan-add scan line-left (+ cury graph-line-wid graph-line-padding) line-width)
                    acc (cons newitem acc)
                    row r))))
      (return (list (reverse acc) scan)))))

(defun graph--pack-tree (scan rows)
  (when rows
    (let* ((row (car rows))
           (more (cdr rows))
           (rowscan (graph-place-boxes scan nil row))
           (row (car rowscan))
           (scan (cadr rowscan))
           (sorted-row (cl-sort row '< :key 'graph-treen-line-y))
           (lps (graph-place-lines scan nil sorted-row))
           (lines-placed (car lps))
           (scan (cadr lps)))
      (cons lines-placed (graph--pack-tree scan more)))))

(defun graph-pack-tree (rows)
  "Get rid of extra empty space in the ROWS by moving up nodes and horizontal lines as much as possible."
  (graph--pack-tree '((0 0)) rows))

(defun graph--idtree (n tree)
  "Assign ids starting at N to the nodes in TREE."
  (let ((labeled
         (mapcar (lambda (nodes)
                   (let* ((nam (car nodes))
                          (chi (cdr nodes))
                          (nchildren (graph--idtree (+ 1 n) chi))
                          (newn (car nchildren))
                          (children (cdr nchildren))
                          (node (make-graph-treen :text (graph-label-text nam)
                                                  :id n :children children)))
                     (setq n newn)
                     node))
                 tree)))
    (cons n labeled)))

(defun graph-idtree (tree)
  "Assign an id number to each node in a TREE so that it can be flattened later on."
  (cdr (graph--idtree 0 tree)))

(defun graph-tree-row-wid (row)
  "Figrue out the width of a ROW in a tree."
  (+ (--reduce-from (+ acc (graph-width-fn (graph-treen-text it))) 0 row)
     (* (- (length row) 1)) graph-node-padding))

(defun graph-layout-tree (tree)
  "Take a TREE and elegantly arrange it."
  (let* ((rows (graph-make-rows tree))
         (wrapped (graph-wrap-text rows))
         (widths (-map 'graph-tree-row-wid wrapped))
         (total-width (apply 'max widths))
         (top 0)
         (left 0)
         (divider (car (graph-positions (apply-partially '= total-width) widths)))
         (pos (cl-mapcar 'list
                         (cl-mapcar 'graph-row-pos wrapped (number-sequence 0 (length wrapped)))
                         widths))
         (zipped-top (reverse (cl-subseq pos 0 divider)))
         (target-row (car (nth divider pos)))
         (zipped-bottom (cl-subseq pos (+ 1 divider)))
         (spaced-top (graph-space 'graph-parent-p total-width target-row zipped-top))
         (spaced-bottom (graph-space 'graph-child-p total-width target-row zipped-bottom))
         (spaced-pos (append (reverse spaced-top) (list target-row) spaced-bottom))
         (lined (graph-horz-lines spaced-pos))
         (leveled-lines (graph-level-lines lined))
         (packed (graph-pack-tree leveled-lines))
         (lev-chi (graph-lev-children packed)))
    (apply 'append lev-chi)))


;;Exported functions for interfacing with this library
;;;###autoload
(defun graph-tree-to-shapes (tree)
  "Return shapes ready to be rendered with `graph-draw-shapes' for the given TREE."
  (graph-integer-shapes (graph--tree-to-shapes (graph-layout-tree (graph-idtree tree)))))

;;;###autoload
(defun graph-draw-tree (tree)
  "Render a TREE and return the text."
  (graph-draw-shapes (graph-tree-to-shapes tree)))

;; (graph-draw-tree '((:north-america (:usa (:miami) (:seattle) (:idaho (:boise)))) (:europe (:germany) (:france (:paris) (:lyon) (:cannes)))))
;; (graph-draw-tree '(("Eubacteria" ("Aquificae") ("Nitrospira") ("Proteobacteria") ("Chlamydiae") ("Actinobacteria")) ("Eukaryotes" ("Archaeplastida" ("Green Plants" ("Prasinophytes") ("Chlorophyceae") ("Trebouxiophyceae") ("Ulvophyceae") ("Streptohyta" ("Zygnematales") ("Charales") ("Embryophytes (land plants)"))) ("Rhodophyta") ("Glaucophytes")) ("Unikots" ("Opisthokonts" ("Animals" ("Bilateria" ("Ecdysozoa" ("Nematoda") ("Arthropoda")) ("Lophotrochozoa") ("Deuterostoma" ("Echinodermata") ("Hemichordata") ("Chordata" ("Urochordata") ("Cephalochordata") ("Yonnanozoon") ("Craniata")))) ("Cnidaria") ("Porifera")) ("Choanoflagellates") ("Filasterea") ("Ichthyosporea") ("Fungi") ("Nucleariidae"))) ("Chromalveolates" ("Rhizaria" ("Cercozoa") ("Foraminifera") ("Radiolaria")) ("Alveolates") ("Stramenopiles") ("Hacrobia")) ("Excavates" ("Malawimonads") ("Discicristates" ("Euglenozoa") ("Heterolobosea")) ("Fornicata")))))


(provide 'graph)
;;; graph.el ends here
