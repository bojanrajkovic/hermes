; tags.scm covers classes, methods, functions, and functions assigned to variables.
(program (lexical_declaration (variable_declarator name: (identifier) @name) @definition.constant))
(program (variable_declaration (variable_declarator name: (identifier) @name) @definition.variable))
(program (export_statement (lexical_declaration (variable_declarator name: (identifier) @name) @definition.constant)))
(program (export_statement (variable_declaration (variable_declarator name: (identifier) @name) @definition.variable)))

(field_definition property: (property_identifier) @name) @definition.field
(field_definition property: (private_property_identifier) @name) @definition.field

; import a, { b, c as d }, * as e from "x" brings in a, b, d, and e.
(import_clause (identifier) @name) @definition.import
(namespace_import (identifier) @name) @definition.import
(import_specifier !alias name: (identifier) @name) @definition.import
(import_specifier alias: (identifier) @name) @definition.import
; const { a, b: c } = require("x") brings in a and c.
(variable_declarator
  name: (object_pattern [
    (shorthand_property_identifier_pattern) @name
    (pair_pattern value: (identifier) @name)])
  value: (call_expression function: (identifier) @_require)
  (#eq? @_require "require")) @definition.import
