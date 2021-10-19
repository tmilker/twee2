require 'rubygems'
require 'haml'
require 'coffee_script'
require 'sass'
require 'builder'

module Twee2
  class StoryFileNotFoundException < Exception; end

  class StoryFile
    attr_accessor :passages
    attr_reader :child_story_files

    HAML_OPTIONS = {
      remove_whitespace: true
    }
    Tilt::CoffeeScriptTemplate.default_bare = true # bare mode for HAML :coffeescript blocks
    COFFEESCRIPT_OPTIONS = {
      bare: true
    }

    # Loads the StoryFile with the given name
    def initialize(filename)
      raise(StoryFileNotFoundException) if !File::exists?(filename)
      @passages, current_passage = {}, nil

      lines = load_file(filename)
      
      # First pass - go through and perform 'includes'
      i, in_story_includes_section = 0, false
      while i < lines.length
        filename, lineno, line = lines[i]
        if line =~ /^:: *StoryIncludes */
          in_story_includes_section = true
        elsif line =~ /^::/
          in_story_includes_section = false
        elsif in_story_includes_section && (line.strip != '')
          child_file = line.strip
          # include a file here because we're in the StoryIncludes section
          if File::exists?(child_file)
            lines[i,0] = load_file(child_file)
          else
            puts "WARNING: tried to include file '#{line.strip}' via StoryIncludes but file was not found."
          end
        elsif line =~ /^( *)::@include (.*)$/
          # include a file here because an @include directive was spotted
          prefix, child_file = $1, $2.strip
          if File::exists?(child_file)
            # insert in-place, with prefix of appropriate amount of whitespace
            lines[i,1] = load_file(child_file)
                         .map{|filename, lineno, line|
                              [filename, lineno,"#{prefix}#{line}"]}
            i-=1 # process this line again, in case of ::@include nesting
          else
            puts "WARNING: tried to ::@include file '#{filename}' but file was not found."
          end
        end
        i+=1
      end
      # Second pass - parse the file
      lines.each do |filename, fileno, line|
        if line =~ /^:: *([^\[]*?) *(\[(.*?)\])? *(<(.*?)>)? *$/
          current_passage = $1.strip
          new_passage = {
            tags: ($3 || '').split(),
            position: $5 || '0,0',
            content: '',
            lines: [],
            exclude_from_output: false,
            pid: nil,
            filename: filename,
            lineno: lineno,
          }
          if @passages.include? current_passage
            old_passage = @passages[current_passage]
            puts "WARNING: passage named #{current_passage} at #{old_passage[:filename]}:#{old_passage[:lineno]} being overwritten by a passage with the same name at #{new_passage[:filename]}:#{new_passage[:lineno]}."
          end
          @passages[current_passage] = new_passage
        elsif current_passage
          @passages[current_passage][:content] << line
          @passages[current_passage][:lines] << [filename, lineno, line]
        end
      end
      @passages.each_key{|k| @passages[k][:content].strip!} # Strip excessive trailing whitespace
      # Run each passage through a preprocessor, if required
      run_preprocessors
      # Extract 'special' passages and mark them as not being included in output
      pid = 0
      @story_css, @story_js, @story_start_name = '', '', 'Start'
      @passages.each_key do |k|
        if k == 'StoryTitle'
          Twee2::build_config.story_name = @passages[k][:content]
          @passages[k][:exclude_from_output] = true
        elsif k == 'StoryIncludes'
          @passages[k][:exclude_from_output] = true # includes should already have been handled above
        elsif @passages[k][:tags].include? 'stylesheet'
          @story_css << "#{@passages[k][:content]}\n"
          @passages[k][:exclude_from_output] = true
        elsif @passages[k][:tags].include? 'script'
          @story_js << "#{@passages[k][:content]}\n"
          @passages[k][:exclude_from_output] = true
        elsif @passages[k][:tags].include? 'twee2'
          eval @passages[k][:content]
          @passages[k][:exclude_from_output] = true
        else
          @passages[k][:pid] = (pid += 1)
        end
      end
    
    def lint
      links = []
      # styles of Twine links
      # bare (link text and name of passage to link to are the same)
      #   [[link]]
      # twine 1 aka |
      #   [[source|dest]]
      # twine 2 style aka ->
      #   [[source->dest]]
      # twine 2 reversed aka <-
      #   [[dest<-source]]
      @passages.each do |passage|
        passage[:lines].each do |filename, lineno, line|
           line
            .scan(%r{\[\[([^\]]*)\]\]})
            .map { |x| x[0] }
            .each do |link|
              # OMG that's a mouthful... but that's a properly quoted/formatted twine link
              if m = link.match(/\A(('(?<lq>([^']|\\')+)')|("(?<lq>([^"]|\\")+)")|(?<l>[^<>|'"]+))(?<style>->|\|)(.+)\Z/)
                links.append({
                  style: m[:style],
                  dest: m[:r],
                  text: unquote(m[:lq]) || m[:l],
                  filename: filename,
                  lineno: lineno,
                })
                next # not malformed
              # valid reverse style link (dest<-text)
              elsif m = link.match(               
                /\A((?<l>.+))(?<style><-)(('(?<rq>[^']|\\')+')|("(?<rq>[^"]|\\")+")|(?<r>[^<>|'"]+))\Z/
              )
                links.append({
                  style: '<-',
                  dest: m[:l],
                  text: unquote(m[:rq]) || m[:r],
                  filename: filename,
                  lineno: lineno,
                })
                next # not malformed
              elsif link.scan('->').length == 1
                style = 'malformed ->'
                text, dest = link.split('->')
              elsif link.scan('<-').length == 1
                style = 'maformed <-'
                dest, text = link.split('<-')
              elsif link.scan('|').length == 1
                style = 'maformed |'
                text, dest = link.split('|')
              else
                links.append({
                  style: 'bare',
                  dest: link,
                  text: link,
                  filename: filename,
                  lineno: lineno,
                })
                next # not malformed
              end
              
              if text.start_with?('\'')
                if !text.end_with?('\'')
                  puts("WARNING #{filename}:#{lineno} link text (#{text.inspect}) does not end with single quote despite starting with one")
                  next
                end
                text = text[1..-2]
                text
                .to_enum(:scan, '\'')
                .map {Regexp.last_match.offset(0)[0]}
                .each do |offset|
                  if text[offset - 1] != '\\'
                    puts "WARNING #{filename}:#{lineno} link text (#{text.inspect}) contains unquoted single quote in body"
                  end
                end
              elsif text.start_with?('"')
                if !text.end_with?('"')
                  puts("WARNING #{filename}:#{lineno} link text (#{text.inspect}) does not end with double quote despite starting with one")
                  next
                end
                text = text[1..-2]
                text
                .to_enum(:scan, '"')
                .map {Regexp.last_match.offset(0)[0]}
                .each do |offset|
                  if text[offset - 1] != '\\'
                    puts "WARNING #{filename}:#{lineno} link text (#{text.inspect}) contains unquoted double quote in body"
                  end
                end
              elsif text =~ /\A[\[\]'"\\]*\Z/
                puts "WARNING #{filename}:#{lineno} link text (#{text.inspect}) contains special characters but is not quoted with single or double quotes"
              end
            end
          end
        end
      end
    end
    
    def unrendered_xml
      @story_start_pid = (@passages[@story_start_name] || {pid: 1})[:pid]
      # Generate XML in Twine 2 format
      story_data = Builder::XmlMarkup.new
      # TODO: what is tw-storydata's "options" attribute for?
      story_data.tag!('tw-storydata', {
                                        name: Twee2::build_config.story_name,
                                   startnode: @story_start_pid,
                                     creator: 'Twee2',
                         'creator-version' => Twee2::VERSION,
                                        ifid: Twee2::build_config.story_ifid,
                                      format: '{{STORY_FORMAT}}',
                            'format-version': '{{STORY_FORMAT_VERSION}}',
                                     options: ''
                      }) do
        story_data.style('{{STORY_CSS}}', role: 'stylesheet', id: 'twine-user-stylesheet', type: 'text/twine-css')
        story_data.script('{{STORY_JS}}', role: 'script', id: 'twine-user-script', type: 'text/twine-javascript')
        @passages.each do |k,v|
          unless v[:exclude_from_output]
            story_data.tag!('tw-passagedata', {
              pid: v[:pid],
              name: k,
              tags: v[:tags].join(' '),
              position: v[:position]
            }, v[:content])
          end
        end
      end
      story_data
    end
    
    # Returns the rendered XML that represents this story
    #NOTE: names is terrible should be called `render` keeping for compatibility
    def xmldata
      unrendered_xml \
        .target! \
        .sub('{{STORY_CSS}}') { @story_css } \
        .sub('{{STORY_JS}}') { @story_js }
    end

    # Runs HAML, Coffeescript etc. preprocessors across each applicable passage
    def run_preprocessors
      @passages.each_key do |k|
        # HAML
        if @passages[k][:tags].include? 'haml'
          @passages[k][:content] = Haml::Engine.new(@passages[k][:content], HAML_OPTIONS).render
          @passages[k][:tags].delete 'haml'
        end
        # Coffeescript
        if @passages[k][:tags].include? 'coffee'
          @passages[k][:content] = CoffeeScript.compile(@passages[k][:content], COFFEESCRIPT_OPTIONS)
          @passages[k][:tags].delete 'coffee'
        end
        # SASS / SCSS
        if @passages[k][:tags].include? 'sass'
          @passages[k][:content] =  Sass::Engine.new(@passages[k][:content], :syntax => :sass).render
        end
        if @passages[k][:tags].include? 'scss'
          @passages[k][:content] =  Sass::Engine.new(@passages[k][:content], :syntax => :scss).render
        end
      end
    end
    private
    def load_file(filename)
      File::read(filename, encoding: 'utf-8')
      .lines
      .each.with_index(1)
      .map{ |line,lineno| [filename, lineno, line] }
    end
  end
end
