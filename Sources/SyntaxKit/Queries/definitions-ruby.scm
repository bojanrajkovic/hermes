; tags.scm covers methods, singleton methods, aliases, classes, and modules.
(assignment left: (constant) @name) @definition.constant
; tags.scm names `def size=(value)` as "size=". This names it "size" as well.
(method name: (setter (identifier) @name)) @definition.method
; attr_accessor :size. The name is a symbol; SyntaxKit drops its leading colon.
((call
  !receiver
  method: (identifier) @_macro
  arguments: (argument_list (simple_symbol) @name)) @definition.property
  (#match? @_macro "^attr_(accessor|reader|writer)$"))
; define_method(:size) and alias_method :size, :count define the first symbol.
((call
  !receiver
  method: (identifier) @_macro
  arguments: (argument_list . (simple_symbol) @name)) @definition.method
  (#match? @_macro "^(define_method|alias_method)$"))
; @size = ... inside initialize declares an instance variable.
((method
  name: (identifier) @_init
  body: (body_statement (assignment left: (instance_variable) @name) @definition.property))
  (#eq? @_init "initialize"))
