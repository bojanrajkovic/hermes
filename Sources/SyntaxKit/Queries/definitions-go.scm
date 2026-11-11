; tags.scm covers functions, methods, and type specs.
(type_alias name: (type_identifier) @name) @definition.type

(source_file (const_declaration (const_spec name: (identifier) @name) @definition.constant))
(source_file (var_declaration (var_spec name: (identifier) @name) @definition.variable))
(source_file (var_declaration (var_spec_list (var_spec name: (identifier) @name) @definition.variable)))

(field_declaration name: (field_identifier) @name) @definition.field
; Interface methods.
(method_elem name: (field_identifier) @name) @definition.method
