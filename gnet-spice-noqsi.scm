;;; gEDA - GPL Electronic Design Automation
;;; gnetlist back end for SPICE
;;; Copyright (C) 2012, 2013 John P. Doty
;;;
;;; This program is free software; you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 2 of the License, or
;;; (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program; if not, write to the Free Software
;;; Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

 (use-modules (srfi srfi-1))

;; Essentially, this back end works by collecting lists of output "cards"
;; and then generating output.
;;
;; "files" holds a list of files to include.
;; "subcircuit" holds the .SUBCKT card, if any.
;; "cards" holds the rest.
;; Note that "cards" is constructed backwards (linked list), so
;; we do the epilog first!

(define (spice-noqsi filename)
    (set-current-output-port(open-output-file filename))
    (write-header)
    (set! packages (get-packages))
    (for-each reserve-refdes packages)
    (for-each collect-file packages)
    (for-each collect-model packages)
    (process-toplevel "spice-epilog")
    (for-each process-part packages)
    (process-toplevel "spice-prolog")
    (if subcircuit (format #t "~A\n" subcircuit))
    (for-each (lambda (s) (format #t "~A\n" s)) cards)
    (hash-for-each (lambda (name data) 
    	(format #t ".MODEL ~A ~A ( ~A )\n" name (car data) (cdr data)))
	models)
    (for-each (lambda (f) (format #t ".INCLUDE ~A\n" f)) files)
    (if subcircuit (format #t ".ENDS\n"))
    (if (positive? error-count) (begin
        (format (current-error-port) "~A errors.\n" error-count)
        (primitive-exit 1))))

;; Lepton compatibility

(define packages #f)	;; legacy gnetlist will redefine

;; Lepton needs this module
(or (defined? 'gnetlist:get-packages) (use-modules (gnetlist schematic)))

;; If packages got defined, use it
;; If not, try the Lepton way
(define (get-packages) 
    (if packages
        (sort packages string<)			;; sort 'cause Lepton does
	(schematic-packages toplevel-schematic)))

(define gnetlist:get-toplevel-attribute
    (if(defined? 'gnetlist:get-toplevel-attribute)
        gnetlist:get-toplevel-attribute
	(lambda (attr) 
	    (or
	        (schematic-toplevel-attrib 
	            toplevel-schematic
                    (string->symbol attr))
                "not found"))))

(define gnetlist:get-pins
    (if (defined? 'gnetlist:get-pins)
        gnetlist:get-pins
        get-pins))
	
	
(define gnetlist:get-nets
    (if (defined? 'gnetlist:get-nets)
        gnetlist:get-nets
        get-nets))
	
;; Write a header. Critical because SPICE may treat the first line
;; as a comment, even if it's not!

(define (write-header)
    (format #t "* ~A\n" (string-join (command-line) " "))
    (format #t
"* SPICE file generated by spice-noqsi version 20170819
* Send requests or bug reports to jpd@noqsi.com
"))


;; Collect file= attribute values.
;; Unlike previous SPICE back ends for gnetlist, this one allows
;; any symbol to request a file to be included.

(define (collect-file refdes)
    (let ((f (gnetlist:get-package-attribute refdes "file")))
        (or (equal? f "unknown")
            (member f files)
            (set! files (cons f files)))))


;; List of files to include

(define files '())

;; Collect model= attribute values.

(define (collect-model refdes)
    (let (
    	(m (gnetlist:get-package-attribute refdes "model"))
	(n (gnetlist:get-package-attribute refdes "model-name"))
	(t (gnetlist:get-package-attribute refdes "type"))
	)
        (or (equal? m "unknown")
            (equal? (hash-get-handle models n) (cons n (cons t m)))
	    (missing-model-name? refdes n)
	    (missing-model-type? refdes t)
	    (model-name-used? refdes n)
            (hash-set! models n (cons t m)))))


;; Hash of models to include

(define models (make-hash-table))

;; Check for model attribute errors

(define (missing-model-name? refdes n)
	(if (equal? n "unknown")
		(begin
			(error-report "~A has a model without a model-name.\n" refdes)
			#t
		)
		#f
	)
)

(define (missing-model-type? refdes t)
	(if (equal? t "unknown")
		(begin
			(error-report "~A has a model without a type.\n" refdes)
			#t
		)
		#f
	)
)

;; 

(define (model-name-used? refdes n)
	(if (hash-ref models n)
		(begin
			(error-report 
"~A has a model-name ~A,
but the name is already in use for a different model.\n"
				refdes n
			)
			#t
		)
		#f
	)
)


;; Include "cards" from appropriate toplevel attributes.

(define (process-toplevel attr)
    (let ((t (gnetlist:get-toplevel-attribute attr)))
    	(or
	    (equal? t "not found") 
	    (collect-card (expand-string #f t)))))


;; To process a part, we must find a suitable prototype,
;; fill in that prototype with instance data, and then figure
;; out if this is an ordinary "card" or a .SUBCKT

(define (process-part refdes)
    (let ((proto (gnetlist:get-package-attribute refdes "spice-prototype")))
        (if (equal? proto "unknown") 
            (set! proto (lookup-proto refdes)))
	(collect-card (expand-string refdes proto))))


;; Put the "card" in the right place

(define (collect-card card)
    (if (string-prefix-ci? ".subckt" card) 
        (subckt card)
        (set! cards (cons card cards))))


;; If no spice-prototype attribute, get prototype according to
;; the device attribute, or use the default for the "unknown"
;; device.

(define (lookup-proto refdes)
    (or 
        (hash-ref prototypes 
            (gnetlist:get-package-attribute refdes "device"))
        (hash-ref prototypes "unknown")))


;; record a subcircuit card, error if more than one

(define (subckt card)
    (if subcircuit
        (begin
            (format (current-error-port) 
                "More than one .subckt card generated!\n")
            (set! error-count (1+ error-count)))
        (set! subcircuit card)))

     
;; This variable will hold the .subckt card if given.

(define subcircuit #f)


;; List of cards in the circuit or subcircuit.
;; Note that a string here might actually represent a group
;; of cards, using embedded newline characters.

(define cards '())


;; If this isn't zero, exit with nonzero status when done.

(define error-count 0)


;; Printing a diagnostic, incrementing error-count, and returning
;; an empty string is a common operation in the code below.
;; (The empty string generally winds up in a required field, so
;; the resulting SPICE file is invalid, which is as it should be).

(define (error-report . args)
    (format (current-error-port) "Error: ")
    (apply format (append (list (current-error-port)) args))
    (set! error-count (1+ error-count))
    "")
    

;; gnetlist associates net with pinnumber, but traditionally SPICE
;; backends for gnetlist have keyed on pinseq. This function implements that.

(define (get-net-by-pinseq refdes n)
    (let* (
        (pinseq (number->string n))
        (pinnumber (gnetlist:get-attribute-by-pinseq 
            refdes pinseq "pinnumber")))

        (if (equal? pinnumber "unknown") 
            (error-report "pinseq=~A not found for refdes=~A
This may indicate an erroneously duplicated refdes.\n" 
		pinseq refdes)
            (get-net refdes pinnumber))))


;; Get the net attached to a particular pin.
;; This really should be a helper in gnetlist.scm, or even
;; replace the partially broken (gnetlist:get-nets).

(define (get-net refdes pin)
    (let ((net (car (gnetlist:get-nets refdes pin))))
        (if (equal? "ERROR_INVALID_PIN" net)
            (error-report "pinnumber=~A not found for refdes=~A\n" pin refdes)
            net)))
            

;; Expand a string in context of a particular refdes
;; This is how we convert symbol data and connections into
;; SPICE cards.

(define (expand-string refdes s)
    (string-concatenate (map
        (lambda (f) (check-field refdes f))
        (parse-fields s))))


;; Split string into whitespace and ink.

(define (parse-fields s)
    (let ((i (or 
        (field-skip s char-set:whitespace)
        (field-skip s 
            (char-set-complement char-set:whitespace)))))

        (if i    
            (append 
                (list (string-take s i))
                (parse-fields (string-drop s i)))
            (list s))))



;; string-skip is a bit difficult to use directly, yielding 0 for no match,
;; and #f when the whole string matches! Yielding only a positive number or
;; #f simplifies the logic above, so that's what I do here.

(define (field-skip s cs)
    (let ((i (string-skip s cs)))
    
    (if i 
        (if (zero? i) 
            #f 
            i)
        #f)))

  
;; Magic characters for field expansion.

(define magic (string->char-set "?#=@%"))


;; Check field for magic, expand if necessary.
;; We only expand a given field once, on the first magic character discovered.

(define (check-field refdes field)
    (let ((i (string-index field magic)))
        (if i 
            (expand-field refdes
                (string-take field i)
                (substring field i (+ i 1))
                (string-drop field (+ i 1)))
            field)))


;; Dispatch to the chosen expander.

(define (expand-field refdes left key right)
    ((cond
        ((equal? key "?") expand-refdes)
        ((equal? key "#") expand-pin)
        ((equal? key "=") expand-attr)
        ((equal? key "@") expand-value)
        ((equal? key "%") expand-variable)) refdes left right))


;; Expand refdes, munging if asked. Note that an empty prefix
;; matches any string, here, so The Right Thing (nothing) happens.

(define (expand-refdes refdes left right)
    (string-append
        (if (string-prefix-ci? left refdes) 
            refdes 
            (get-munged left refdes))
        right))


;; Replace "unknown" with a default

(define (get-value-or-default refdes attr default)
    (if (equal? value "unknown") default value))


;; forward and reverse refdes maps

(define munges (make-hash-table))
(define refdes-reserved (make-hash-table))


;; prevent munging from accidentally duplicating an existing refdes
;; by reserving all existing refdeses.

(define (reserve-refdes r) (hash-set! refdes-reserved r r))


;; Get the munged version of refdes
;; 

(define (get-munged prefix refdes)
    (or 
        (hash-ref munges (list prefix refdes))
        (make-munged prefix refdes (string-append prefix refdes))))


;; Make unique munged version.
;; Recursively append X until we have a unique refdes.

(define (make-munged prefix refdes candidate)
    (if (hash-ref refdes-reserved candidate)
        (make-munged prefix refdes (string-append candidate "X"))
        (begin
            (hash-set! refdes-reserved candidate refdes)
            (hash-set! munges (list prefix refdes) candidate))))


;; Get name of net connected to pin.
;; The only issue is whether "left" specifies an alternate refdes.

(define (expand-pin refdes left right)
    (if (equal? left "")
        (get-net refdes right)
        (get-net left right)))


;; Expand "%" variables.
;; For now, reconstruct input for unrecognized ones. Should be error instead?

(define (expand-variable refdes left right)
    (string-append left
        (cond
            ((equal? right "pinseq") (all-by-pinseq refdes))
            ((equal? right "io") (all-spice-io))
	    ((equal? right "up") (all-up))
	    ((equal? right "down") (all-down refdes))
	    (#t (string-append "%" right)))))

;; get nets attached to SPICE io pins

(define (all-spice-io)
    (string-join
        (map pin-1 
	    (sort-spice-io (spice-io-pins))) 
	" "))


;; get net attached to pin 1 (of I/O symbol)

(define (pin-1 p) (get-net p "1"))

;; string->number, ignoring non-numeric chars

(define (numeric->number s) (string->number (string-filter s char-numeric?)))

;; Make a list of (number . refdes) pairs

(define (number-packages lp) 
    (map (lambda (p) (cons (numeric->number p)  p)) lp))

;; Sort a list of refdes by their numeric parts  

(define (sort-spice-io p)
    (map cdr (sort (number-packages p) 
       (lambda (p1 p2) (< (car p1) (car p2))))))

;; find SPICE subcircuit IO pin symbols

(define (spice-io-pins)
    (filter
    	(lambda (p) 
	    (equal? "spice-IO" 
	        (gnetlist:get-package-attribute p "device"))) packages ))

;; get all net connections in pinseq order

(define (all-by-pinseq refdes)
    (or (slot-problem? refdes (string->number 
        (gnetlist:get-package-attribute refdes "numslots")))
        (string-join
            (map
                (lambda (n) (get-net-by-pinseq refdes n))
                (iota (length (gnetlist:get-pins refdes)) 1))
            " ")))


;; Check for slotting, error if present. Return "" on error, #f otherwise.

(define (slot-problem? refdes numslots)
    (if (and numslots (positive? numslots))
        (error-report
"~A uses slotting. You must list its connections by pinnumber,\n  not pinseq.\n" 
                refdes)
       #f))
       
            
;; Expand attribute. Result is name=value.
;; Empty string if it doesn't exist, and no default given.

(define (expand-attr refdes name default)
    (let ((value (expand-value refdes name default)))
        (if (equal? value "")
            ""
            (string-append name "=" value))))


;; Expand value. Empty string if it doesn't exist, and no default given.
;; Deal with the fact that missing attributes may either be "unknown"
;; or "not found" :(

(define (expand-value refdes name default)
    (let ((value (get-attribute refdes name)))
        (if (or (equal? value "unknown") (equal? value "not found"))
            default
            value)))

;; Select either package attribute or toplevel attribute

(define (get-attribute refdes name)
    (if refdes
        (gnetlist:get-package-attribute refdes name)
	(gnetlist:get-toplevel-attribute name)))
	

;; List input/output symbols in lexical order

(define (all-up)
    (string-join
        (map pin-1 
	    (sort (io-pins) string<?)) 
	" "))


;; Track down input/output symbols

(define (io-pins)
    (filter 
        (lambda (p) (let ((device (gnetlist:get-package-attribute p "device")))
	    (or
	    	(equal? "INPUT" device)
		(equal? "OUTPUT" device)
		(equal? "IO" device))))
	packages))


;; get all net connections in lexical pinlabel order

(define (all-down refdes)
    (string-join
	(map
	    (lambda (p) (get-net refdes p))
	    (pins-by-label refdes))
	" "))


;; list pins sorted by pinlabel

(define (pins-by-label refdes)
    (map cdr
        (sort (labels-pins refdes)
	    (lambda (p1 p2) (string<? (car p1) (car p2))))))


;; list pinlabels and pins

(define (labels-pins refdes)
    (map 
        (lambda (p) 
	    (cons 
	        (gnetlist:get-attribute-by-pinnumber refdes p "pinlabel")
		p ))
	(gnetlist:get-pins refdes)))


;; Default prototypes by device
;; Note that the "unknown" prototype applies to all unlisted devices.

(define prototypes (make-hash-table))

(define (spice-device device proto) (hash-set! prototypes device proto))

;; Standard prototypes. Most of these are intended to be similar to the 
;; hard-wired behavior of spice-sdb.

(spice-device "unknown" "? %pinseq value@ model-name@ spice-args@")
(spice-device "AOP-Standard" "X? %pinseq model-name@")
(spice-device "BATTERY" "V? #1 #2 spice-args@")
(spice-device "SPICE-cccs" "F? #1 #2 V? value@\nV? #3 #4 DC 0")
(spice-device "SPICE-ccvs" "H? #1 #2 V? value@\nV? #3 #4 DC 0")
(spice-device "directive" "value@")
(spice-device "include" "*")               ; just a place to hang file=
(spice-device "options" ".OPTIONS value@")
(spice-device "CURRENT_SOURCE" "I? %pinseq value@")
(spice-device "K" "K? inductors@ value@")
(spice-device "SPICE-nullor" "N? %pinseq value@1E6")
(spice-device "SPICE-NPN" "Q? %pinseq model-name@ spice-args@ ic= temp=")
(spice-device "PNP_TRANSISTOR" "Q? %pinseq model-name@ spice-args@ ic= temp=")
(spice-device "NPN_TRANSISTOR" "Q? %pinseq model-name@ spice-args@ ic= temp=")
(spice-device "spice-subcircuit-LL" ".SUBCKT model-name@ %io")
(spice-device "spice-IO" "*")
(spice-device "SPICE-VC-switch" "S? %pinseq model-name@ value@")
(spice-device "T-line" "T? %pinseq value@")
(spice-device "vac" "V? %pinseq value@")
(spice-device "SPICE-vccs" "G? %pinseq value@")
(spice-device "SPICE-vcvs" "E? %pinseq value@")
(spice-device "VOLTAGE_SOURCE" "V? %pinseq value@")
(spice-device "vexp" "V? %pinseq value@")
(spice-device "vpulse" "V? %pinseq value@")
(spice-device "vpwl" "V? %pinseq value@")
(spice-device "vsin" "V? %pinseq value@")
(spice-device "VOLTAGE_SOURCE" "V? %pinseq value@")
(spice-device "INPUT" "*")
(spice-device "OUTPUT" "*")
(spice-device 
    "CAPACITOR" "C? %pinseq value@ model-name@ spice-args@ l= w= area= ic=")
(spice-device "DIODE" "D? %pinseq model-name@ spice-args@ area= ic= temp=")
(spice-device "NMOS_TRANSISTOR" 
    "M? %pinseq model-name@ spice-args@ l= w= as= ad= pd= ps= nrd= nrs= temp= ic= m=")
(spice-device "PMOS_TRANSISTOR" 
    "M? %pinseq model-name@ spice-args@ l= w= as= ad= pd= ps= nrd= nrs= temp= ic= m=")
(spice-device "RESISTOR" 
    "R? %pinseq value@ model-name@ spice-args@ w= l= area= temp=")
(spice-device "DUAL_OPAMP" 
    "X1? #3 #2 #8 #4 #1 model-name@\nX2? #5 #6 #8 #4 #7 model-name@")
(spice-device "QUAD_OPAMP"
    "X1? #3 #2 #11 #4 #1 model-name@
X2? #5 #6 #11 #4 #7 model-name@
X3? #10 #9 #11 #4 #8 model-name@
X4? #12 #13 #11 #4 #14 model-name@")
(spice-device "model" "* refdes@")

