; tags.scm covers structs, enums, unions, type aliases, traits, modules, macros,
; functions, and methods in impl blocks.
(const_item name: (identifier) @name) @definition.constant
(static_item name: (identifier) @name) @definition.variable
(field_declaration name: (field_identifier) @name) @definition.field
(enum_variant name: (identifier) @name) @definition.constant
; Trait methods without a body.
(function_signature_item name: (identifier) @name) @definition.method
(associated_type name: (type_identifier) @name) @definition.type
