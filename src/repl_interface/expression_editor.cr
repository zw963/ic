require "./term_cursor"
require "./term_size"
require "../highlighter"

module IC::ReplInterface
  # ExpressionEditor allows to edit and display an expression:
  #
  # Usage example:
  # ```
  # # new editor:
  # @editor = ExpressionEditor.new(
  #   prompt: ->(expr_line_number : Int32) { "prompt> " }
  # )
  #
  # # edit some code:
  # @editor.update do
  #   @editor << %(puts "World")
  #
  #   insert_new_line(indent: 1)
  #   @editor << %(puts "!")
  # end
  #
  # # move cursor:
  # @editor.move_cursor_up
  # 4.times { @editor.move_cursor_left }
  #
  # # edit:
  # @editor.update do
  #   @editor << "Hello "
  # end
  #
  # @editor.end_editing
  #
  # @editor.expression # => %(puts "Hello World"\n  puts "!")
  # puts "=> ok"
  #
  # # clear and restart edition:
  # @editor.prompt_next
  # ```
  #
  # The above has displayed:
  #
  # prompt> puts "Hello World"
  # prompt>   puts "!"
  # => ok
  # prompt>
  #
  class ExpressionEditor
    getter lines : Array(String) = [""]
    getter expression : String? { lines.join('\n') }
    getter expression_height : Int32? { lines.sum { |l| line_height(l) } }
    getter colorized_lines : Array(String)? do
      @highlighter.highlight(self.expression, toggle: color?).split('\n')
    end

    property? color = true

    @highlighter = Highlighter.new
    @prompt : Int32, Bool -> String
    @prompt_size : Int32

    # Tracks the cursor position relatively to the expression's lines, (y=0 corresponds to the first line and x=0 the first char)
    # This position is independent of text wrapping so its position will not match to real cursor on screen.
    #
    # `|` : cursor position
    #
    # ```
    # prompt> def very_looo
    # ooo|ng_name            <= wrapping
    # prompt>   bar
    # prompt> end
    # ```
    # For example here the cursor position is x=16, y=0, but real cursor is at x=3,y=1 from the beginning of expression.
    getter x = 0
    getter y = 0

    @scroll_offset = 0

    # Prompt size must stay constant.
    def initialize(&@prompt : Int32, Bool -> String)
      @prompt_size = @prompt.call(0, false).size # uncolorized size

      at_exit { print Term::Cursor.show }
    end

    private def move_cursor(x, y)
      @x += x
      @y += y
    end

    private def move_real_cursor(x, y)
      print Term::Cursor.move(x, -y)
    end

    private def move_abs_cursor(@x, @y)
    end

    private def reset_cursor
      @x = @y = 0
    end

    def current_line
      @lines[@y]
    end

    def previous_line?
      if @y > 0
        @lines[@y - 1]
      end
    end

    def next_line?
      @lines[@y + 1]?
    end

    def cursor_on_last_line?
      (@y == @lines.size - 1)
    end

    def expression_before_cursor(x = @x, y = @y)
      @lines[...y].join('\n') + '\n' + current_line[..x]
    end

    # Following functions modifies the expression, they should be called inside
    # an `update` block to see the changes in the screen : #

    def previous_line=(line)
      @lines[@y - 1] = line
      @expression = @expression_height = @colorized_lines = nil
    end

    def current_line=(line)
      @lines[@y] = line
      @expression = @expression_height = @colorized_lines = nil
    end

    def next_line=(line)
      @lines[@y + 1] = line
      @expression = @expression_height = @colorized_lines = nil
    end

    # `"`, `:`, `'`, are not a delimiter because symbols and strings should be treated as one word.
    # ditto for '!', '?'
    WORD_DELIMITERS = /[ \n\t\+\-,;@&%=<>*\/\\\[\]\(\)\{\}\|\.\~]/

    def word_bound(x = @x, y = @y)
      line = @lines[y]
      word_begin = line.rindex(WORD_DELIMITERS, offset: {x - 1, 0}.max) || -1
      word_end = line.index(WORD_DELIMITERS, offset: x) || line.size

      {word_begin + 1, word_end - 1}
    end

    def delete_line(y)
      @lines.delete_at(y)
      @expression = @expression_height = @colorized_lines = nil
    end

    def <<(char : Char)
      return insert_new_line(0) if char.in? '\n', '\r'

      if @x >= current_line.size
        self.current_line = current_line + char
      else
        self.current_line = current_line.insert(@x, char)
      end

      move_cursor(x: +1, y: 0)
      self
    end

    def <<(str : String)
      str.each_char do |ch|
        self << ch
      end
    end

    def insert_new_line(indent)
      case @x
      when current_line.size
        @lines.insert(@y + 1, "  "*indent)
      when .< current_line.size
        @lines.insert(@y + 1, "  "*indent + current_line[@x..])
        self.current_line = current_line[...@x]
      end

      @expression = @expression_height = @colorized_lines = nil
      move_abs_cursor(x: indent*2, y: @y + 1)
    end

    def delete
      case @x
      when current_line.size
        if next_line = next_line?
          self.current_line = current_line + next_line

          delete_line(@y + 1)
        end
      when .< current_line.size
        self.current_line = current_line.delete_at(@x)
      end
    end

    def back
      case @x
      when 0
        if prev_line = previous_line?
          self.previous_line = prev_line + current_line

          move_cursor(x: prev_line.size, y: -1)
          delete_line(@y + 1)
        end
      when .> 0
        self.current_line = current_line.delete_at(@x - 1)
        move_cursor(x: -1, y: 0)
      end
    end

    # End modifying functions. #

    # Gives the size of the last part of the line when it's wrapped
    #
    # prompt> def very_looo
    # ooooooooong              <= last part
    # prompt>   bar
    # prompt> end
    #
    # e.g. here "ooooooooong".size = 10
    private def remaining_size(line_size)
      (@prompt_size + line_size) % Term::Size.width
    end

    # Returns the part number *p* of this line:
    private def part(line, p)
      first_part_size = (Term::Size.width - @prompt_size)
      if p == 0
        line[0...first_part_size]
      else
        line[(first_part_size + (p - 1)*Term::Size.width)...(first_part_size + p*Term::Size.width)]
      end
    end

    # Returns the height of this line, (1 on common lines, more on wrapped lines):
    private def line_height(line)
      1 + (@prompt_size + line.size) // Term::Size.width
    end

    def move_cursor_left(allow_scrolling = true)
      case @x
      when 0
        # Wrap the cursor at the end of the previous line:
        #
        # `|`: cursor pos
        # `*`: wanted pos
        #
        # ```
        # prompt> def very_looo
        # ooooooooong*
        # prompt> | bar
        # prompt> end
        # ```
        if prev_line = previous_line?
          scroll_up_if_needed if allow_scrolling

          # Wrap real cursor:
          size_of_last_part = remaining_size(prev_line.size)
          move_real_cursor(x: -@prompt_size + size_of_last_part, y: -1)

          # Wrap cursor:
          move_cursor(x: prev_line.size, y: -1)
        end
      when .> 0
        # Move the cursor left, wrap the real cursor if needed:
        #
        # `|`: cursor pos
        # `*`: wanted pos
        #
        # ```
        # prompt> def very_looo*
        # |oooooooong
        # prompt>   bar
        # prompt> end
        # ```
        if remaining_size(@x) == 0
          scroll_up_if_needed if allow_scrolling
          move_real_cursor(x: Term::Size.width + 1, y: -1)
        else
          move_real_cursor(x: -1, y: 0)
        end
        move_cursor(x: -1, y: 0)
      end
    end

    def move_cursor_right(allow_scrolling = true)
      case @x
      when current_line.size
        # Wrap the cursor at the beginning of the next line:
        #
        # `|`: cursor pos
        # `*`: wanted pos
        #
        # ```
        # prompt> def very_looo
        # ooooooooong|
        # prompt> * bar
        # prompt> end
        # ```
        if next_line?
          scroll_down_if_needed if allow_scrolling

          # Wrap real cursor:
          size_of_last_part = remaining_size(current_line.size)
          move_real_cursor(x: -size_of_last_part + @prompt_size, y: +1)

          # Wrap cursor:
          move_cursor(x: -current_line.size, y: +1)
        end
      when .< current_line.size
        # Move the cursor right, wrap the real cursor if needed:
        #
        # `|`: cursor pos
        # `*`: wanted pos
        #
        # ```
        # prompt> def very_looo|
        # *oooooooong
        # prompt>   bar
        # prompt> end
        # ```
        if remaining_size(@x) == (Term::Size.width - 1)
          scroll_down_if_needed if allow_scrolling

          move_real_cursor(x: -Term::Size.width, y: +1)
        else
          move_real_cursor(x: +1, y: 0)
        end

        # move cursor right
        move_cursor(x: +1, y: 0)
      end
    end

    def move_cursor_up
      scroll_up_if_needed

      if (@prompt_size + @x) >= Term::Size.width
        if @x >= Term::Size.width
          # Here, we have:
          # ```
          # prompt> def *very_loo
          # oooooooooooo|oooooooo
          # ooooooooong
          # prompt>   bar
          # prompt> end
          # ```
          # So we need only to move real cursor up
          # and move back @x by term-width.
          #
          move_real_cursor(x: 0, y: -1)
          move_cursor(x: -Term::Size.width, y: 0)
        else
          # Here, we have:
          # ```
          # prompt> *def very_loo
          # ooo|ooooooooooooooooo
          # ooooooooong
          # prompt>   bar
          # prompt> end
          # ```
          #
          move_real_cursor(x: Term::Size.width - @x, y: -1)
          move_cursor(x: 0 - @x, y: 0)
        end

        true
      elsif prev_line = previous_line?
        # Here, there are a previous line in which we can move up, we want to
        # move on the last part of the previous line:
        size_of_last_part = remaining_size(prev_line.size)

        if size_of_last_part < @prompt_size + @x
          # ```
          # prompt> def very_loo
          # oooooooooooooooooooo
          # ong*                  <= last part
          # prompt>   ba|aar
          # prompt> end
          # ```
          move_real_cursor(x: -@x - @prompt_size + size_of_last_part, y: -1)
          move_abs_cursor(x: prev_line.size, y: @y - 1)
        else
          # ```
          # prompt> def very_loo
          # oooooooooooooooooooo
          # oooooooooooo*oong    <= last part
          # prompt>   ba|aar
          # prompt> end
          # ```
          move_real_cursor(x: 0, y: -1)
          x = prev_line.size - size_of_last_part + @prompt_size + @x
          move_abs_cursor(x: x, y: @y - 1)
        end
        true
      else
        false
      end
    end

    def move_cursor_down
      scroll_down_if_needed

      size_of_last_part = remaining_size(current_line.size)
      real_x = remaining_size(@x)

      remaining = current_line.size - @x

      if remaining > size_of_last_part
        # on middle
        if remaining > Term::Size.width
          # Here, there are enough remaining to just move down
          # ```
          # prompt>  def ve|ry_loo
          # ooooooooooooooo*oooooo
          # ong
          # prompt>   bar
          # prompt> end
          # ```
          #
          move_real_cursor(x: 0, y: +1)
          move_cursor(x: Term::Size.width, y: 0)
        else
          # Here, we goes to end of current line:
          # ```
          # prompt>  def very_loo
          # ooooooooooooooo|ooooo
          # ong*
          # prompt>   bar
          # prompt> end
          # ```
          move_real_cursor(x: -real_x + size_of_last_part, y: +1)
          move_abs_cursor(x: current_line.size, y: @y)
        end
        true
      elsif next_line = next_line?
        case real_x
        when .< @prompt_size
          # Here, we are behind the prompt so we want goes to the beginning of the next line:
          # ```
          # prompt>  def very_loo
          # ooooooooooooooooooooo
          # ong|
          # prompt> * bar
          # prompt> end
          # ```
          move_real_cursor(x: -real_x + @prompt_size, y: +1)
          move_abs_cursor(x: 0, y: @y + 1)
        when .< @prompt_size + next_line.size
          # Here, we can just move down on the next line:
          # ```
          # prompt>  def very_loo
          # ooooooooooooooooooooo
          # ooooooooong|
          # prompt>   b*ar
          # prompt> end
          # ```
          move_real_cursor(x: 0, y: +1)
          move_abs_cursor(x: real_x - @prompt_size, y: @y + 1)
        else
          # Finally, here, we want to move at end of the next line:
          # ```
          # prompt>  def very_loo
          # ooooooooooooooooooooo
          # ooooooooooooooong|
          # prompt>   bar*
          # prompt> end
          # ```
          x = real_x - (@prompt_size + next_line.size)
          move_real_cursor(x: -x, y: +1)
          move_abs_cursor(x: next_line.size, y: @y + 1)
        end
        true
      else
        false
      end
    end

    def move_cursor_to(x, y, allow_scrolling = true)
      if y > @y || (y == @y && x > @x)
        # Destination is after, move cursor forward:
        until {@x, @y} == {x, y}
          move_cursor_right(allow_scrolling: false)
          raise "Bug: position (#{x}, #{y}) missed when moving cursor forward" if @y > y
        end
      else
        # Destination is before, move cursor backward:
        until {@x, @y} == {x, y}
          move_cursor_left(allow_scrolling: false)
          raise "Bug: position (#{x}, #{y}) missed when moving cursor backward" if @y < y
        end
      end

      if allow_scrolling && update_scroll_offset
        update
      end
    end

    def move_cursor_to_begin(allow_scrolling = true)
      move_cursor_to(0, 0, allow_scrolling: allow_scrolling)
    end

    def move_cursor_to_end(allow_scrolling = true)
      y = @lines.size - 1

      move_cursor_to(@lines[y].size, y, allow_scrolling: allow_scrolling)
    end

    def move_cursor_to_end_of_first_line(allow_scrolling = true)
      move_cursor_to(@lines[0].size, 0, allow_scrolling: allow_scrolling)
    end

    # Rewinds the cursor to the beginning of the expression
    # then yields for modifications, and displays the new expression.
    # cursor is adjusted to not overflow if the new expression is smaller.
    def update(force_full_view = false, &)
      print Term::Cursor.hide
      rewind_cursor

      with self yield

      @expression = @expression_height = @colorized_lines = nil

      # Updated expression can be smaller and we might need to adjust the cursor:
      @y = @y.clamp(0, @lines.size - 1)
      @x = @x.clamp(0, @lines[@y].size)

      print_expression(force_full_view)
      print Term::Cursor.show
    end

    def update(force_full_view = false)
      print Term::Cursor.hide
      rewind_cursor

      print_expression(force_full_view)
      print Term::Cursor.show
    end

    def replace(lines : Array(String))
      update { @lines = lines.dup }
    end

    def end_editing(replace : Array(String)? = nil)
      end_editing(replace) { }
    end

    # Yields a callback called after rewind the cursor and before reprint the replacement.
    def end_editing(replace : Array(String)? = nil, &)
      if replace
        update(force_full_view: true) do
          yield
          @lines = replace
        end
      else
        update(force_full_view: true) do
          yield
        end
      end

      move_cursor_to_end(allow_scrolling: false)
      puts
    end

    def prompt_next
      @scroll_offset = 0
      @lines = [""]
      @expression = @expression_height = @colorized_lines = nil
      reset_cursor
      print @prompt.call(0, color?)
    end

    def scroll_up
      if @scroll_offset < expression_height() - Term::Size.height
        @scroll_offset += 1
        update
      end
    end

    def scroll_down
      if @scroll_offset > 0
        @scroll_offset -= 1
        update
      end
    end

    private def scroll_up_if_needed
      if update_scroll_offset(y_shift: -1)
        update
      end
    end

    private def scroll_down_if_needed
      if update_scroll_offset(y_shift: +1)
        update
      end
    end

    # Updates the scroll offset in a way that (cursor + y_shift) is still between the view bounds
    # Returns true if the offset has been effectively modified.
    private def update_scroll_offset(y_shift = 0)
      start, end_ = view_bounds
      real_y = @lines.each.first(@y).sum { |l| line_height(l) }
      real_y += line_height(current_line[..@x]) - 1
      real_y += y_shift

      # case 1: cursor is before view start, we need to increase the scroll by the difference.
      if real_y < start
        @scroll_offset += start - real_y
        true

        # case 2: cursor is after view end, we need to decrease the scroll by the difference.
      elsif real_y > end_
        @scroll_offset -= real_y - end_
        true
      else
        false
      end
    end

    private def view_bounds
      h = Term::Size.height
      end_ = expression_height() - 1

      start = {0, end_ + 1 - h}.max

      @scroll_offset = @scroll_offset.clamp(0, start)

      start -= @scroll_offset
      end_ -= @scroll_offset
      {start, end_}
    end

    # Rewind the real cursor to the beginning of the expression without changing @x/@y cursor:
    private def rewind_cursor
      if expression_height >= Term::Size.height
        print Term::Cursor.row(1)
      else
        x_save, y_save = @x, @y
        move_cursor_to_begin(allow_scrolling: false)
        @x, @y = x_save, y_save
      end

      print Term::Cursor.column(1)
    end

    private def print_line(io, colorized_line, line_index, line_size, prompt?, first?, is_last_part?)
      if prompt?
        io.puts unless first?
        io.print @prompt.call(line_index, color?)
      end
      io.print colorized_line

      # ```
      # prompt> begin                  |
      # prompt>   foooooooooooooooooooo|
      #                                | <- If the line size match exactly the screen width, we need to add a
      # prompt>   bar                  |    extra line feed, so computes based on `%` or `//` stay exact.
      # prompt> end                    |
      # ```
      io.puts if is_last_part? && remaining_size(line_size) == 0
    end

    # Prints the colorized expression, this last is clipped if it's higher than screen.
    # The only displayed part of the expression is delimited by `view_bounds` and depend of the value of
    # `@scroll_offset`.
    # Lines that takes more than one line (if wrapped) are cut in consequence.
    private def print_expression(force_full_view = false)
      if force_full_view
        start, end_ = 0, Int32::MAX
      else
        update_scroll_offset()

        start, end_ = view_bounds()
      end

      first = true

      y = 0

      # Track the real cursor position so we are able to correctly retrieve it to its original position (before clearing screen):
      real_cursor_x = real_cursor_y = 0

      display = String.build do |io|
        # Iterate over the uncolored lines because we need to know the true size of each line:
        @lines.each_with_index do |line, line_index|
          line_height = line_height(line)

          break if y > end_

          if start <= y && y + line_height - 1 <= end_
            # The line can hold entirely between the view bound, print it:
            print_line(io, colorized_lines[line_index], line_index, line.size, prompt?: true, first?: first, is_last_part?: true)
            first = false

            real_cursor_x = line.size
            real_cursor_y = line_index

            y += line_height
          else
            # The line cannot holds entirely between the view bound, we need to check each part individually:
            line_height.times do |part_number|
              if start <= y <= end_
                # The part holds on the view, we can print it.
                # FIXME:
                # /!\ Because we cannot extract the part from the colorized line (inserted escape colors makes impossible to know when it wraps), we need to
                # recolor the part individually.
                # This lead to a wrong coloration!, but should not happen often (wrapped long lines, on expression higher than screen, scrolled on border of the view).
                colorized_line = @highlighter.highlight(part(line, part_number), toggle: color?)

                print_line(io, colorized_line, line_index, line.size, prompt?: part_number == 0, first?: first, is_last_part?: part_number == line_height - 1)
                first = false

                real_cursor_x = {line.size, (part_number + 1)*Term::Size.width - @prompt_size - 1}.min
                real_cursor_y = line_index
              end
              y += 1
            end
          end
        end
      end

      print Term::Cursor.clear_screen_down
      print display

      # Retrieve the real cursor at its corresponding cursor position (`@x`, `@y`)
      x_save, y_save = @x, @y
      @y = real_cursor_y
      @x = real_cursor_x
      move_cursor_to(x_save, y_save, allow_scrolling: false)
    end
  end
end
