require 'parser/current'

module Solargraph
  class CodeMap
    attr_accessor :node
    attr_accessor :api_map
    
    include NodeMethods
    
    def initialize code, api_map: ApiMap.new, require_nodes: {}, workspace: nil
      @api_map = api_map.dup
      @api_map.workspace = workspace
      @code = code
      tries = 0
      # Hide incomplete code to avoid syntax errors
      tmp = "#{code}\nX".gsub(/[\.@]([\s])/, '#\1').gsub(/([\A\s]?)def([\s]*?[\n\Z])/, '\1#ef\2')
      #tmp = code.gsub(/[\.@]([\s])/, '#\1').gsub(/([\A\s]?)def([\s]*?[\n\Z])/, '\1#ef\2')
      begin
        @node, comments = Parser::CurrentRuby.parse_with_comments(tmp)
        @api_map.merge(@node, comments)
      rescue Parser::SyntaxError => e
        if tries < 10
          tries += 1
          spot = e.diagnostic.location.begin_pos
          if spot == tmp.length
            puts e.message
            tmp = tmp[0..-2] + '#'
          else
            tmp = tmp[0..spot] + '#' + tmp[spot+2..-1].to_s
          end
          retry
        end
        raise e
      end
    end

    def merge node
      api_map.merge node
    end

    def tree_at(index)
      arr = []
      #if index >= @node.loc.expression.begin_pos and index < @node.loc.expression.end_pos
        arr.push @node
        #if match = code[1..-1].match(/^[\s]*end/)
        #  index -= 1
        #end
        inner_node_at(index, @node, arr)
      #end
      arr
    end

    def node_at(index)
      tree_at(index).first
    end

    def string_at?(index)
      n = node_at(index)
      n.kind_of?(AST::Node) and n.type == :str
    end

    def parent_node_from(index, *types)
      arr = tree_at(index)
      arr.each { |a|
        if a.kind_of?(AST::Node) and types.include?(a.type)
          return a
        end
      }
      @node
    end

    def namespace_at(index)
      tree = tree_at(index)
      return nil if tree.length == 0
      node = parent_node_from(index, :module, :class)
      slice = tree[(tree.index(node) || 0)..-1]
      parts = []
      slice.reverse.each { |n|
        if n.type == :class or n.type == :module
          parts.push unpack_name(n.children[0])
        end
      }
      parts.join("::")
    end

    def phrase_at index
      word = ''
      cursor = index - 1
      while cursor > -1
        char = @code[cursor, 1]
        #puts "***#{char}"
        break if char.nil? or char == ''
        break unless char.match(/[\s;=\(\)\[\]\{\}]/).nil?
        word = char + word
        cursor -= 1
      end
      word
    end

    def word_at index
      word = ''
      cursor = index - 1
      while cursor > -1
        char = @code[cursor, 1]
        #puts "***#{char}"
        break if char.nil? or char == ''
        break unless char.match(/[a-z0-9_]/i)
        word = char + word
        cursor -= 1
      end
      word      
    end

    def get_instance_variables_at(index)
      node = parent_node_from(index, :def, :defs, :class, :module)
      ns = namespace_at(index) || ''
      @api_map.get_instance_variables(ns, (node.type == :def ? :instance : :class))
    end

    def suggest_at index, filtered: true, with_snippets: false
      return [] if string_at?(index)
      result = []
      phrase = phrase_at(index)
      if phrase.start_with?('@')
        if phrase.include?('.')
          result = []
          # TODO: Temporarily assuming one period
          var = phrase[0..phrase.index('.')-1]
          ns = namespace_at(index)
          obj = @api_map.infer_instance_variable(var, ns)
          result = @api_map.get_instance_methods(obj) unless obj.nil?
        else
          result = get_instance_variables_at(index)
        end
      elsif phrase.start_with?('$')
        result += @api_map.get_global_variables
      elsif phrase.start_with?(':') and !phrase.start_with?('::')
        # TODO: It's a symbol. Nothing to do for now.
        return []
      elsif phrase.include?('::')
        parts = phrase.split('::', -1)
        ns = parts[0..-2].join('::')
        if parts.last.include?('.')
          ns = parts[0..-2].join('::') + '::' + parts.last[0..parts.last.index('.')-1]
          result = @api_map.get_methods(ns)
        else
          result = @api_map.namespaces_in(ns)
        end
      elsif phrase.include?('.')
        # It's a method call
        # TODO: For now we're assuming only one period. That's obviously a bad assumption.
        base = phrase[0..phrase.index('.')-1]
        ns_here = namespace_at(index)
        if @api_map.namespace_exists?(base, ns_here)
          result = @api_map.get_methods(base, ns_here)
        else
          scope = parent_node_from(index, :class, :module, :def, :defs) || @node
          var = find_local_variable_node(base, scope)
          unless var.nil?
            obj = infer(var.children[1])
            result = @api_map.get_instance_methods(obj) unless obj.nil?
          end
          #result = reduce(results, word_at(index)) unless unfiltered
        end
      else
        current_namespace = namespace_at(index)
        parts = current_namespace.to_s.split('::')
        result += get_snippets_at(index) if with_snippets
        result += get_local_variables_and_methods_at(index) + ApiMap.get_keywords(without_snippets: with_snippets)
        while parts.length > 0
          ns = parts.join('::')
          result += @api_map.namespaces_in(ns)
          parts.pop
        end
        result += @api_map.namespaces_in('')
      end
      result = reduce_starting_with(result, word_at(index)) if filtered
      result
    end
    
    def get_snippets_at(index)
      result = []
      Snippets.definitions.each_pair { |name, detail|
        matched = false
        prefix = detail['prefix']
        while prefix.length > 0
          if @code[index-prefix.length, prefix.length] == prefix
            matched = true
            break
          end
          prefix = prefix[0..-2]
        end
        if matched
          result.push Suggestion.new(detail['prefix'], kind: Suggestion::KEYWORD, detail: name, insert: detail['body'].join("\r\n"))
        end
      }
      result
    end

    def get_local_variables_and_methods_at(index)
      result = []
      local = parent_node_from(index, :class, :module, :def, :defs) || @node
      result += get_local_variables_from(local)
      scope = namespace_at(index) || @node
      if local.type == :def
        result += @api_map.get_instance_methods(scope)
      else
        result += @api_map.get_methods(scope)
      end
      result += @api_map.get_methods('Kernel')
      result    
    end
    
    private

    def reduce_starting_with(suggestions, word)
      suggestions.reject { |s|
        !s.label.start_with?(word)
      }
    end

    def get_local_variables_from(node)
      node ||= @node
      arr = []
      node.children.each { |c|
        if c.kind_of?(AST::Node)
          if c.type == :lvasgn
            arr.push Suggestion.new(c.children[0], kind: Suggestion::VARIABLE)
          else
            arr += get_local_variables_from(c)
          end
        end
      }
      arr
    end
    
    def inner_node_at(index, node, arr)
      node.children.each { |c|
        if c.kind_of?(AST::Node)
          unless c.loc.expression.nil?
            if index >= c.loc.expression.begin_pos #+ @code[index..-1].match(/^[\s]*?/).to_s.length
              if index < c.loc.expression.end_pos
                # HACK: If this is a scoped node, make sure the index isn't in preceding whitespace
                unless [:module, :class, :def].include?(c.type) and @code[index..-1].match(/^[\s]*?#{c.type}/)
                  arr.unshift c
                end
              else
                match = @code[index..-1].match(/^[\s]*?end/)
                if match and index < c.loc.expression.end_pos + match.to_s.length
                  arr.unshift c
                end
              end
            end
          end
          inner_node_at(index, c, arr)
        end
      }
    end
    
    def find_local_variable_node name, scope
      scope.children.each { |c|
        if c.kind_of?(AST::Node)
          if c.type == :lvasgn and c.children[0].to_s == name
            return c
          else
            unless [:class, :module, :def, :defs].include?(c.type)
              sub = find_local_variable_node(name, c)
              return sub unless sub.nil?
            end
          end
        end
      }
      nil
    end
    
  end
end