module Solargraph
  module Pin
    class Namespace < Pin::Base
      include Solargraph::NodeMethods

      attr_reader :visibility

      attr_reader :type

      # @return [Pin::Reference]
      attr_reader :superclass_reference

      def initialize location, namespace, name, docstring, type, visibility, superclass
        super(location, namespace, name, docstring)
        @type = type
        @visibility = visibility
        # @superclass_reference = Reference.new(self, superclass) unless superclass.nil?
        @superclass_reference = Pin::Reference.new(location, namespace, superclass) unless superclass.nil?
      end

      # @return [Array<Pin::Reference>]
      def include_references
        @include_references ||= []
      end

      # @return [Array<String>]
      def extend_references
        @extend_references ||= []
      end

      def kind
        Pin::NAMESPACE
      end

      def named_context
        path
      end

      def scope
        :class
      end

      def completion_item_kind
        (type == :class ? LanguageServer::CompletionItemKinds::CLASS : LanguageServer::CompletionItemKinds::MODULE)
      end

      def path
        @path ||= (namespace.empty? ? '' : "#{namespace}::") + name
      end

      def return_type
        @return_type ||= (type == :class ? 'Class' : 'Module') + "<#{path}>"
      end
    end
  end
end
