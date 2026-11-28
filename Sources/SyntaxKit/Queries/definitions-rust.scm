; tags.scm covers structs, enums, unions, type aliases, traits, modules, macros,
; functions, and methods in impl blocks.
(const_item name: (identifier) @name) @definition.constant
(static_item name: (identifier) @name) @definition.variable
(field_declaration name: (field_identifier) @name) @definition.field
(enum_variant name: (identifier) @name) @definition.constant
; Trait methods without a body.
(function_signature_item name: (identifier) @name) @definition.method
(associated_type name: (type_identifier) @name) @definition.type

; use x::{A, b::C, D as E} brings in A, C, and E.
(use_declaration argument: (identifier) @name) @definition.import
(use_declaration argument: (scoped_identifier name: (identifier) @name)) @definition.import
(use_list (identifier) @name) @definition.import
(use_list (scoped_identifier name: (identifier) @name)) @definition.import
(use_as_clause alias: (identifier) @name) @definition.import
