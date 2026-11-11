; resource "aws_instance" "web" {}, variable "region" {}: the last label is the name.
((block . (identifier) @_type (string_lit (template_literal) @name) . (block_start)) @definition.variable
  (#not-eq? @_type "module"))

((block . (identifier) @_type (string_lit (template_literal) @name) . (block_start)) @definition.module
  (#eq? @_type "module"))

; locals { name = ... }
((block . (identifier) @_type (body (attribute (identifier) @name) @definition.variable))
  (#eq? @_type "locals"))
