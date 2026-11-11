; tags.scm covers classes, methods, functions, and functions assigned to variables.
(program (lexical_declaration (variable_declarator name: (identifier) @name) @definition.constant))
(program (variable_declaration (variable_declarator name: (identifier) @name) @definition.variable))
(program (export_statement (lexical_declaration (variable_declarator name: (identifier) @name) @definition.constant)))
(program (export_statement (variable_declaration (variable_declarator name: (identifier) @name) @definition.variable)))

(field_definition property: (property_identifier) @name) @definition.field
(field_definition property: (private_property_identifier) @name) @definition.field
