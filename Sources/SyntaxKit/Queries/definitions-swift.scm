; tags.scm covers classes, structs, enums, actors, protocols, functions, methods,
; and stored or computed properties.
(class_declaration "extension" name: (user_type (type_identifier) @name)) @definition.type
(typealias_declaration name: (type_identifier) @name) @definition.type
(enum_entry name: (simple_identifier) @name) @definition.constant
(protocol_property_declaration name: (pattern (simple_identifier) @name)) @definition.property
(associatedtype_declaration name: (type_identifier) @name) @definition.type
