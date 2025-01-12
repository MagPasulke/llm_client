CLASS zcl_llm_tool_calculator DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES zif_llm_tool.

    TYPES: BEGIN OF calculation_input,
             expression TYPE string,
           END OF calculation_input.

    TYPES: BEGIN OF calculation_output,
             result TYPE string,
           END OF calculation_output.

  PRIVATE SECTION.
    TYPES: BEGIN OF token,
             value     TYPE string,
             is_number TYPE abap_bool,
           END OF token.
    TYPES tokens TYPE STANDARD TABLE OF token WITH EMPTY KEY.

    CONSTANTS:
      operator_plus     TYPE string VALUE '+',
      operator_minus    TYPE string VALUE '-',
      operator_multiply TYPE string VALUE '*',
      operator_divide   TYPE string VALUE '/',
      operator_power    TYPE string VALUE '**',
      operator_mod      TYPE string VALUE 'MOD'.

    METHODS:
      evaluate_expression
        IMPORTING expression    TYPE string
        RETURNING VALUE(result) TYPE string
        RAISING   cx_sy_zerodivide
                  cx_sy_arithmetic_error
                  cx_sy_conversion_no_number,

      tokenize
        IMPORTING expression    TYPE string
        RETURNING VALUE(result) TYPE tokens
        RAISING   cx_sy_conversion_no_number,

      parse_number
        IMPORTING number_string TYPE string
        RETURNING VALUE(result) TYPE decfloat34
        RAISING   cx_sy_conversion_no_number,

      get_operator_precedence
        IMPORTING operator      TYPE string
        RETURNING VALUE(result) TYPE i,

      evaluate_tokens
        IMPORTING tokens        TYPE tokens
        RETURNING VALUE(result) TYPE decfloat34
        RAISING   cx_sy_zerodivide
                  cx_sy_arithmetic_error
                  cx_sy_conversion_no_number,

      apply_operator
        IMPORTING operator      TYPE string
                  operand1      TYPE decfloat34
                  operand2      TYPE decfloat34
        RETURNING VALUE(result) TYPE decfloat34
        RAISING   cx_sy_zerodivide
                  cx_sy_arithmetic_error
                  cx_sy_conversion_no_number,

      process_operator
        IMPORTING operator       TYPE string
        CHANGING  operator_stack TYPE string_table
                  output_queue   TYPE tokens,

      evaluate_rpn
        IMPORTING tokens        TYPE tokens
        RETURNING VALUE(result) TYPE decfloat34
        RAISING   cx_sy_zerodivide cx_sy_arithmetic_error
                  cx_sy_conversion_no_number,

      pop_from_stack
        CHANGING  stack         TYPE STANDARD TABLE
        RETURNING VALUE(result) TYPE string,

      peek_stack
        CHANGING  stack         TYPE STANDARD TABLE
        RETURNING VALUE(result) TYPE string.

    DATA int_result TYPE calculation_output.
    DATA int_tool_call_id TYPE string.

ENDCLASS.


CLASS zcl_llm_tool_calculator IMPLEMENTATION.
  METHOD zif_llm_tool~get_tool_details.
    DATA parameters TYPE zif_llm_tool=>tool_parameters.

    parameters-data_desc    ?= cl_abap_typedescr=>describe_by_name( 'CALCULATION_INPUT' ).

    parameters-descriptions  = VALUE #(
        ( fieldname   = 'EXPRESSION'
          description = 'Mathematical expression to evaluate. Supports +, -, *, /, **, MOD and parentheses' ) ) ##NO_TEXT.

    result = VALUE #( name        = 'calculator'
                      description = 'Evaluates mathematical expressions. Supports +, -, *, /, **, MOD and parentheses' ##NO_TEXT
                      type        = zif_llm_tool=>type_function
                      parameters  = parameters ).
  ENDMETHOD.

  METHOD zif_llm_tool~execute.
    DATA input  TYPE calculation_input.
    DATA output TYPE calculation_output.

    ASSIGN data->* TO FIELD-SYMBOL(<data>).
    input = <data>.

    TRY.
        output-result = evaluate_expression( input-expression ).
      CATCH cx_sy_conversion_no_number.
        output-result = |Error: Invalid expression: { input-expression }| ##NO_TEXT.
      CATCH cx_sy_zerodivide.
        output-result = |Error: Division by zero| ##NO_TEXT.
    ENDTRY.

    result-data         = REF #( output ).
    result-name         = `calculator`.
    result-tool_call_id = tool_call_id.

    " Save internal result
    int_result = output.
    int_tool_call_id = tool_call_id.
  ENDMETHOD.

  METHOD zif_llm_tool~get_result.
    result = VALUE #( data         = REF #( int_result )
                      tool_call_id = int_tool_call_id
                      name         = `calculator` ).
  ENDMETHOD.

  METHOD evaluate_expression.
    IF expression IS INITIAL.
      RAISE EXCEPTION NEW cx_sy_conversion_no_number( ).
    ENDIF.

    DATA(cleaned_expr) = replace( val   = expression
                                  regex = `\s`
                                  with  = ``
                                  occ   = 0 ).
    DATA(tokens) = tokenize( cleaned_expr ).
    DATA(calc_result) = evaluate_tokens( tokens ).
    result = |{ calc_result NUMBER = USER }|.
  ENDMETHOD.

  METHOD tokenize.
    DATA current_token TYPE string.
    DATA current_char  TYPE c LENGTH 1.
    DATA length        TYPE i.
    DATA index         TYPE i VALUE 0.
    DATA next_pos      TYPE i.

    length = strlen( expression ) - 1.

    WHILE index <= length.
      current_char = expression+index(1).

      CASE current_char.
        WHEN '0' OR '1' OR '2' OR '3' OR '4' OR '5' OR '6' OR '7' OR '8' OR '9' OR '.'.
          CLEAR current_token.
          WHILE index <= length AND expression+index(1) CA '0123456789.'.
            current_token = current_token && expression+index(1).
            index = index + 1.
          ENDWHILE.
          index = index - 1.
          APPEND VALUE #( value     = current_token
                          is_number = abap_true ) TO result.

        WHEN '(' OR ')' OR '+' OR '*' OR '/' OR 'M'.
          " Check for MOD operator
          IF     current_char         = 'M'
             AND index + 2           <= length
             AND expression+index(3)  = 'MOD'.
            APPEND VALUE #( value     = 'MOD'
                            is_number = abap_false ) TO result.
            index = index + 2.
            " Check for ** operator
          ELSEIF     current_char = '*'
                 AND index        < length.
            next_pos = index + 1.
            IF expression+next_pos(1) = '*'.
              APPEND VALUE #( value     = '**'
                              is_number = abap_false ) TO result.
              index = index + 1.
            ELSE.
              APPEND VALUE #( value     = current_char
                              is_number = abap_false ) TO result.
            ENDIF.
          ELSE.
            APPEND VALUE #( value     = current_char
                            is_number = abap_false ) TO result.
          ENDIF.

        WHEN '-'.
          " Check if this is a negative number (when it's the first token or follows an operator or opening parenthesis)
          IF    result IS INITIAL
             OR (     lines( result ) > 0
                  AND (    result[ lines( result ) ]-value = '('
                        OR result[ lines( result ) ]-value = '+'
                        OR result[ lines( result ) ]-value = '-'
                        OR result[ lines( result ) ]-value = '*'
                        OR result[ lines( result ) ]-value = '/'
                        OR result[ lines( result ) ]-value = '**'
                        OR result[ lines( result ) ]-value = 'MOD' ) ).
            " This is a negative number - read the number part
            next_pos = index + 1.
            IF next_pos <= length AND expression+next_pos(1) CA '0123456789.'.
              current_token = '-'.
              index = index + 1.
              WHILE index <= length AND expression+index(1) CA '0123456789.'.
                current_token = current_token && expression+index(1).
                index = index + 1.
              ENDWHILE.
              index = index - 1.
              APPEND VALUE #( value     = current_token
                              is_number = abap_true ) TO result.
            ELSE.
              " Just a minus operator
              APPEND VALUE #( value     = current_char
                              is_number = abap_false ) TO result.
            ENDIF.
          ELSE.
            " Just a minus operator
            APPEND VALUE #( value     = current_char
                            is_number = abap_false ) TO result.
          ENDIF.

        WHEN space.
          " Ignore spaces
          CONTINUE.

        WHEN OTHERS.
          " Raise exception for invalid characters
          RAISE EXCEPTION NEW cx_sy_conversion_no_number( value = CONV #( current_char ) ).
      ENDCASE.
      index = index + 1.
    ENDWHILE.

    " If no tokens were created, raise an exception
    IF result IS INITIAL.
      RAISE EXCEPTION NEW cx_sy_conversion_no_number( ).
    ENDIF.
  ENDMETHOD.

  METHOD get_operator_precedence.
    CASE operator.
      WHEN '(' OR ')'.
        result = 0.
      WHEN '+' OR '-'.
        result = 1.
      WHEN '*' OR '/' OR 'MOD'.
        result = 2.
      WHEN '**'.
        result = 3.
    ENDCASE.
  ENDMETHOD.

  METHOD evaluate_tokens.
    DATA output_queue   TYPE tokens.
    DATA operator_stack TYPE string_table.
    DATA token          TYPE token.

    " Shunting yard algorithm
    LOOP AT tokens INTO token.
      IF token-is_number = abap_true.
        APPEND token TO output_queue.
      ELSEIF token-value = '('.
        APPEND token-value TO operator_stack.
      ELSEIF token-value = ')'.
        WHILE operator_stack IS NOT INITIAL AND peek_stack( CHANGING stack = operator_stack ) <> '('.
          APPEND VALUE #( value     = pop_from_stack( CHANGING stack = operator_stack )
                          is_number = abap_false )
                 TO output_queue.
        ENDWHILE.
        IF operator_stack IS NOT INITIAL.
          pop_from_stack( CHANGING stack = operator_stack ). " Remove '('
        ENDIF.
      ELSE.
        process_operator( EXPORTING operator       = token-value
                          CHANGING  operator_stack = operator_stack
                                    output_queue   = output_queue ).
      ENDIF.
    ENDLOOP.

    " Move remaining operators to output
    WHILE operator_stack IS NOT INITIAL.
      APPEND VALUE #( value     = pop_from_stack( CHANGING stack = operator_stack )
                      is_number = abap_false )
             TO output_queue.
    ENDWHILE.

    " Evaluate RPN
    result = evaluate_rpn( output_queue ).
  ENDMETHOD.

  METHOD process_operator.
    WHILE     operator_stack IS NOT INITIAL
          AND peek_stack( CHANGING stack = operator_stack ) <> '('
          AND get_operator_precedence( peek_stack( CHANGING stack = operator_stack ) ) >=
              get_operator_precedence( operator ).
      APPEND VALUE #( value     = pop_from_stack( CHANGING stack = operator_stack )
                      is_number = abap_false )
             TO output_queue.
    ENDWHILE.
    APPEND operator TO operator_stack.
  ENDMETHOD.

  METHOD evaluate_rpn.
    DATA value_stack TYPE STANDARD TABLE OF decfloat34.
    DATA operand1    TYPE decfloat34.
    DATA operand2    TYPE decfloat34.

    LOOP AT tokens INTO DATA(token).
      IF token-is_number = abap_true.
        APPEND parse_number( token-value ) TO value_stack.
      ELSE.
        IF lines( value_stack ) < 2.
          RAISE EXCEPTION NEW cx_sy_conversion_no_number( ).
        ENDIF.

        operand2 = value_stack[ lines( value_stack ) ].
        DELETE value_stack INDEX lines( value_stack ).
        operand1 = value_stack[ lines( value_stack ) ].
        DELETE value_stack INDEX lines( value_stack ).

        APPEND apply_operator( operator = token-value
                               operand1 = operand1
                               operand2 = operand2 )
               TO value_stack.
      ENDIF.
    ENDLOOP.

    IF lines( value_stack ) = 1.
      result = value_stack[ 1 ].
    ELSE.
      RAISE EXCEPTION NEW cx_sy_conversion_no_number( ).
    ENDIF.
  ENDMETHOD.

  METHOD pop_from_stack.
    DATA(last_index) = lines( stack ).
    IF last_index > 0.
      result = stack[ last_index ].
      DELETE stack INDEX last_index.
    ENDIF.
  ENDMETHOD.

  METHOD peek_stack.
    DATA(last_index) = lines( stack ).
    IF last_index > 0.
      result = stack[ last_index ].
    ENDIF.
  ENDMETHOD.

  METHOD parse_number.
    result = CONV decfloat34( number_string ).
  ENDMETHOD.

  METHOD apply_operator.
    CASE operator.
      WHEN '+'.
        result = operand1 + operand2.
      WHEN '-'.
        result = operand1 - operand2.
      WHEN '*'.
        result = operand1 * operand2.
      WHEN '/'.
        IF operand2 = 0.
          RAISE EXCEPTION NEW cx_sy_zerodivide( ).
        ENDIF.
        result = operand1 / operand2.
      WHEN '**'.
        " Handle negative exponents
        IF operand2 < 0.
          IF operand1 = 0.
            RAISE EXCEPTION NEW cx_sy_zerodivide( ).
          ENDIF.
          result = 1 / ( operand1 ** abs( operand2 ) ).
        ELSE.
          result = operand1 ** operand2.
        ENDIF.
      WHEN 'MOD'.
        IF operand2 = 0.
          RAISE EXCEPTION NEW cx_sy_zerodivide( ).
        ENDIF.
        result = operand1 - ( operand2 * trunc( operand1 / operand2 ) ).
      WHEN OTHERS.
        RAISE EXCEPTION NEW cx_sy_conversion_no_number( ).
    ENDCASE.
  ENDMETHOD.

ENDCLASS.
