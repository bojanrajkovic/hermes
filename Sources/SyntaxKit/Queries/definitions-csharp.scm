; tags.scm covers classes, interfaces, methods, and namespaces.
(struct_declaration name: (identifier) @name) @definition.type
(enum_declaration name: (identifier) @name) @definition.type
(record_declaration name: (identifier) @name) @definition.type
(delegate_declaration name: (identifier) @name) @definition.type
(file_scoped_namespace_declaration name: (identifier) @name) @definition.module

(enum_member_declaration name: (identifier) @name) @definition.constant
(property_declaration name: (identifier) @name) @definition.property
(field_declaration (variable_declaration (variable_declarator name: (identifier) @name))) @definition.field
(event_field_declaration (variable_declaration (variable_declarator name: (identifier) @name))) @definition.field
(local_function_statement name: (identifier) @name) @definition.function
; record Point(int X, int Y) declares properties.
(record_declaration (parameter_list (parameter name: (identifier) @name) @definition.property))
