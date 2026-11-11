; Highlights for HCL and Terraform. tree-sitter-hcl ships no queries.

(comment) @comment

(bool_lit) @constant.builtin
(null_lit) @constant.builtin
(numeric_lit) @number

(string_lit) @string
(quoted_template) @string
(heredoc_template) @string
(heredoc_identifier) @string

(template_interpolation) @embedded
(template_directive) @embedded
[
  (template_interpolation_start)
  (template_interpolation_end)
  (template_directive_start)
  (template_directive_end)
  (strip_marker)
  (ellipsis)
] @punctuation.special

(identifier) @variable
(attribute (identifier) @property)
(get_attr (identifier) @property)
(object_elem key: (expression (variable_expr (identifier) @property)))
(function_call (identifier) @function)

; The block type: resource, variable, module, ...
(block . (identifier) @keyword)

((variable_expr (identifier) @variable.builtin)
  (#match? @variable.builtin "^(var|local|module|data|path|terraform|each|count|self)$"))

["for" "in" "if" "else" "endif" "endfor"] @keyword

["!" "!=" "%" "&&" "*" "+" "-" "/" "<" "<=" "=" "==" "=>" ">" ">=" "?" ":" "||"] @operator

[
  (block_start) (block_end)
  (object_start) (object_end)
  (tuple_start) (tuple_end)
  "(" ")" "[" "]" "[*]" ".*"
] @punctuation.bracket

["," "."] @punctuation.delimiter
