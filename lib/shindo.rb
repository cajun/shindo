require 'rubygems'
require 'annals'
require 'formatador'

module Shindo

  def self.tests(description = nil, tags = [], &block)
    STDOUT.sync = true
    Shindo::Tests.new(description, tags, &block)
  end

  class Tests

    attr_accessor :backtrace

    def initialize(description, tags = [], &block)
      @afters     = []
      @annals     = Annals.new
      @befores    = []
      @formatador = Formatador.new
      @success    = true
      @tag_stack  = []
      Thread.current[:reload] = false;
      Thread.current[:tags] ||= []
      @if_tagged      = Thread.current[:tags].
                          select {|tag| tag.match(/^\+/)}.
                          map {|tag| tag[1..-1]}
      @unless_tagged  = Thread.current[:tags].
                          select {|tag| tag.match(/^\-/)}.
                          map {|tag| tag[1..-1]}
      @formatador.display_line('')
      tests(description, tags, &block)
      @formatador.display_line('')
      Thread.current[:success] = @success
    end

    def after(&block)
      @afters[-1].push(block)
    end

    def before(&block)
      @befores[-1].push(block)
    end

    def prompt(description, &block)
      @formatador.display("Action? [c,e,i,q,r,t,#,?]? ")
      choice = STDIN.gets.strip
      @formatador.display_line
      case choice
      when 'c', 'continue'
        return
      when /^e .*/, /^eval .*/
        @formatador.display_line(eval(choice[2..-1], block.binding))
      when 'i', 'interactive', 'irb'
        @formatador.display_line('Starting interactive session...')
        if @irb.nil?
          require 'irb'
          ARGV.clear # Avoid passing args to IRB
          IRB.setup(nil)
          @irb = IRB::Irb.new(nil)
          IRB.conf[:MAIN_CONTEXT] = @irb.context
          IRB.conf[:PROMPT][:SHINDO] = {}
        end
        for key, value in IRB.conf[:PROMPT][:SIMPLE]
          IRB.conf[:PROMPT][:SHINDO][key] = "#{@formatador.indentation}#{value}"
        end
        @irb.context.prompt_mode = :SHINDO
        @irb.context.workspace = IRB::WorkSpace.new(block.binding)
        begin
          @irb.eval_input
        rescue SystemExit
        end
      when 'q', 'quit', 'exit'
        Thread.current[:success] = false
        Thread.exit
      when 'r', 'reload'
        @formatador.display_line("Reloading...")
        Thread.current[:reload] = true
        Thread.exit
      when 't', 'backtrace', 'trace'
        @formatador.indent do
          if @annals.lines.empty?
            @formatador.display_line('no backtrace available')
          else
            @annals.lines.each_with_index do |line, index|
              @formatador.display_line("#{' ' * (2 - index.to_s.length)}#{index}  #{line}")
            end
          end
        end
      when '?', 'help'
        @formatador.display_line('c - ignore this error and continue')
        @formatador.display_line('i - interactive mode')
        @formatador.display_line('q - quit Shindo')
        @formatador.display_line('r - reload and run the tests again')
        @formatador.display_line('t - display backtrace')
        @formatador.display_line('# - enter a number of a backtrace line to see its context')
        @formatador.display_line('? - display help')
      when /\d/
        index = choice.to_i - 1
        if @annals.lines[index]
          @formatador.indent do
            @formatador.display_line("#{@annals.lines[index]}: ")
            @formatador.indent do
              @formatador.display("\n")
              current_line = @annals.buffer[index]
              File.open(current_line[:file], 'r') do |file|
                data = file.readlines
                current = current_line[:line]
                min     = [0, current - (@annals.max / 2)].max
                max     = [current + (@annals.max / 2), data.length].min
                min.upto(current - 1) do |line|
                  @formatador.display_line("#{line}  #{data[line].rstrip}")
                end
                @formatador.display_line("[yellow]#{current}  #{data[current].rstrip}[/]")
                (current + 1).upto(max - 1) do |line|
                  @formatador.display_line("#{line}  #{data[line].rstrip}")
                end
              end
            end
          end
        else
          @formatador.display_line("[red]#{choice} is not a valid backtrace line, please try again.[/]")
        end
      else
        @formatador.display_line("[red]#{choice} is not a valid choice, please try again.[/]")
      end
      @formatador.display_line
      @formatador.display_line("[red]- #{description}[/]")
      prompt(description, &block)
    end

    def tests(description, tags = [], &block)
      tags = [*tags]
      @tag_stack.push(tags)
      @befores.push([])
      @afters.push([])

      taggings = ''
      unless tags.empty?
        taggings = " (#{tags.join(', ')})"
      end

      @formatador.display_line((description || 'Shindo.tests') << taggings)
      if block_given?
        @formatador.indent { instance_eval(&block) }
      end

      @afters.pop
      @befores.pop
      @tag_stack.pop
    end

    def test(description, tags = [], &block)
      tags = [*tags]
      @tag_stack.push(tags)
      taggings = ''
      unless tags.empty?
        taggings = " (#{tags.join(', ')})"
      end

      # if the test includes +tags and discludes -tags, evaluate it
      if (@if_tagged.empty? || !(@if_tagged & @tag_stack.flatten).empty?) &&
          (@unless_tagged.empty? || (@unless_tagged & @tag_stack.flatten).empty?)
        if block_given?
          begin
            for before in @befores.flatten.compact
              before.call
            end

            @annals.start
            success = instance_eval(&block)
            @annals.stop

            for after in @afters.flatten.compact
              after.call
            end
          rescue => error
            @annals.stop
            success = false
            file, line, method = error.backtrace.first.split(':')
            method << "#{method && "in #{method[4...-1]} "}! #{error.message} (#{error.class})"
            @annals.unshift(:file => file, :line => line.to_i, :method => method)
            @formatador.display_line("[red]#{error.message} (#{error.class})[/]")
          end
          @success = @success && success
          if success
            @formatador.display_line("[green]+ #{description}#{taggings}[/]")
          else
            @formatador.display_line("[red]- #{description}#{taggings}[/]")
            if STDOUT.tty?
              prompt(description, &block)
            end
          end
        else
          @formatador.display_line("[yellow]* #{description}#{taggings}[/]")
        end
      else
        @formatador.display_line("_ #{description}#{taggings}")
      end

      @tag_stack.pop
    end

  end

end
