require "compiler/crystal/interpreter"
require "option_parser"
require "./repl_interface/repl_interface"
require "./pry"
require "./errors"

module IC
  VERSION = "0.3.2"

  def self.run_file(repl, path, argv)
    repl.run_file(path, argv)
  end

  def self.run(repl)
    color = repl.program.color?

    repl.public_load_prelude

    input = ReplInterface::ReplInterface.new
    input.color = color
    input.repl = repl

    input.run do |expr|
      result = repl.run_next_code(expr)
      puts " => #{Highlighter.highlight(result.to_s, toggle: color)}"
    rescue ex : Crystal::Repl::EscapingException
      print "Unhandled exception: "
      print ex
    rescue ex : Crystal::CodeError
      repl.clean

      ex.color = color
      ex.error_trace = true
      puts ex
    rescue ex : Exception
      ex.inspect_with_backtrace(STDOUT)
    end

    puts
  end
end

class Crystal::Repl
  def create_parser(code)
    Parser.new(
      code,
      string_pool: @program.string_pool,
      var_scopes: [@interpreter.local_vars.names_at_block_level_zero.to_set]
    )
  end

  def run_next_code(code)
    node = create_parser(code).parse
    interpret(node)
  end

  def public_load_prelude
    load_prelude
  end

  def clean
    @main_visitor.clean
  end
end

class Crystal::MainVisitor
  def clean
    @exp_nest = 0 # Avoid the error "can't declare def dynamically"
    @in_type_args = 0
  end
end
