; The TypeScript and JavaScript tags.scm cover classes, interfaces, methods,
; functions, and functions assigned to variables.
(type_alias_declaration name: (type_identifier) @name) @definition.type
(enum_declaration name: (identifier) @name) @definition.type
(internal_module name: (identifier) @name) @definition.module

(program (lexical_declaration (variable_declarator name: (identifier) @name) @definition.constant))
(program (variable_declaration (variable_declarator name: (identifier) @name) @definition.variable))
(program (export_statement (lexical_declaration (variable_declarator name: (identifier) @name) @definition.constant)))
(program (export_statement (variable_declaration (variable_declarator name: (identifier) @name) @definition.variable)))

(public_field_definition name: (property_identifier) @name) @definition.field
(property_signature name: (property_identifier) @name) @definition.field
(public_field_definition name: (private_property_identifier) @name) @definition.field

; enum Color { Red, Green = 2 }
(enum_body name: (property_identifier) @name) @definition.constant
(enum_assignment name: (property_identifier) @name) @definition.constant
; constructor(private readonly repo: Repo) declares a field.
(required_parameter (accessibility_modifier) pattern: (identifier) @name) @definition.field
