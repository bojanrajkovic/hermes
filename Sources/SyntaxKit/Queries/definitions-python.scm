; tags.scm covers classes, functions, and module-level assignments.
(class_definition body: (block (function_definition name: (identifier) @name) @definition.method))
(class_definition body: (block (decorated_definition definition: (function_definition name: (identifier) @name) @definition.method)))
(class_definition body: (block (expression_statement (assignment left: (identifier) @name) @definition.field)))
; self.name = ... inside __init__ declares an instance attribute.
((function_definition
  name: (identifier) @_init
  body: (block (expression_statement (assignment
    left: (attribute object: (identifier) @_self attribute: (identifier) @name)) @definition.field)))
  (#eq? @_init "__init__")
  (#eq? @_self "self"))
