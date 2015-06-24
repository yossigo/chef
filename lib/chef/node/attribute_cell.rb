require 'chef/node/attribute_constants'
require 'chef/node/attribute_trait/immutablize'
require 'chef/node/vivid_mash'

class Chef
  class Node
    class AttributeCell

      #
      # There are dangerous and unpredictable ways to use the internals of this API:
      #
      # 1.  Mutating an interior hash/array into a bare value (particularly nil)
      # 2.  Using individual setters/getters at anything other than the top level (always use
      #     node.default['foo'] not node['foo'].default)
      #

      include AttributeConstants

      attr_accessor :default
      attr_accessor :env_default
      attr_accessor :role_default
      attr_accessor :force_default
      attr_accessor :normal
      attr_accessor :override
      attr_accessor :role_override
      attr_accessor :env_override
      attr_accessor :force_override
      attr_accessor :automatic

      def initialize(default: nil, env_default: nil, role_default: nil, force_default: nil,
                     normal: nil,
                     override: nil, role_override: nil, env_override: nil, force_override: nil,
                     automatic: nil)
        self.default        = default
        self.env_default    = env_default
        self.role_default   = role_default
        self.force_default  = force_default
        self.normal         = normal
        self.override       = override
        self.role_override  = role_override
        self.env_override   = env_override
        self.force_override = force_override
        self.automatic      = automatic
      end

      COMPONENTS_AS_SYMBOLS.each do |component|
        define_method :"#{component}=" do |value|
          instance_variable_set(
            :"@#{component}",
            if value.is_a?(Hash) || value.is_a?(Array)
              Chef::Node::VividMash.new(wrapped_object: value)
            else
              value
            end
          )
        end
      end

      def kind_of?(klass)
        highest_precedence.kind_of?(klass) || super(klass)
      end

      def is_a?(klass)
        highest_precedence.is_a?(klass) || super(klass)
      end

      def kind_of?(klass)
        highest_precedence.kind_of?(klass) || super(klass)
      end

      def eql?(other)
        if is_a?(Hash)
          return false unless other.is_a?(Hash)
          merged_hash.each do |key, value|
            return false unless merged_hash[key].eql?(other[key])
          end
          return true
        elsif is_a?(Array)
          return false unless other.is_a?(Array)
          merged_array.each_with_index do |value, i|
            return false unless value.eql?(other[i])
          end
          return true
        else
          highest_precedence.eql?(other)
        end
      end

      def ==(other)
        if is_a?(Hash)
          return false unless other.is_a?(Hash)
          merged_hash.each do |key, value|
            return false unless merged_hash[key] == other[key]
          end
        elsif is_a?(Array)
          return false unless other.is_a?(Array)
          merged_array.each_with_index do |value, i|
            return false unless value == other[i]
          end
        else
          highest_precedence == other
        end
      end

      def ===(other)
        as_simple_object === other
      end

      def to_s
        as_simple_object.to_s
      end

      def method_missing(method, *args, &block)
        as_simple_object.public_send(method, *args, &block)
      end

      def respond_to?(method, include_private = false)
        as_simple_object.respond_to?(method, include_private) || key?(method.to_s)
      end

      def [](key)
        if self.is_a?(Hash)
          merged_hash[key]
        elsif self.is_a?(Array)
          merged_array[key]
        else
          # this should never happen - should probably freeze this or dump/load
          return highest_precedence[key]
        end
      end

      def combined_default
        return self.class.new(
          default: @default,
          env_default: @env_default,
          role_default: @role_default,
          force_default: @force_default,
        )
      end

      def combined_override
        return self.class.new(
          override: @override,
          role_override: @role_override,
          env_override: @env_override,
          force_override: @force_override,
        )
      end

      def each(&block)
        return enum_for(:each) unless block_given?

        if self.is_a?(Hash)
          merged_hash.each do |key, value|
            yield key, value
          end
        elsif self.is_a?(Array)
          merged_array.each do |value|
            yield value
          end
        else
          yield highest_precedence
        end
      end

      def to_json(*opts)
        Chef::JSONCompat.to_json(to_hash, *opts)
      end

      def to_hash
        if self.is_a?(Hash)
          h = {}
          each do |key, value|
            if value.is_a?(Hash)
              h[key] = value.to_hash
            elsif value.is_a?(Array)
              h[key] = value.to_a
            else
              h[key] = value
            end
          end
          h
        elsif self.is_a?(Array)
          raise # FIXME
        else
          highest_precedence.to_hash
        end
      end

      def to_a
        if self.is_a?(Hash)
          raise # FIXME
        elsif self.is_a?(Array)
          a = []
          each do |value|
            if value.is_a?(Hash)
              a.push(value.to_hash)
            elsif value.is_a?(Array)
              a.push(value.to_a)
            else
              a.push(value)
            end
          end
          a
        else
          highest_precedence.to_a
        end
      end

      alias_method :to_ary, :to_a

      private

      def as_simple_object
        if self.is_a?(Hash)
          merged_hash
        elsif self.is_a?(Array)
          merged_array
        else
          # in normal usage we never wrap non-containers, so this should never happen
          highest_precedence
        end
      end

      def merged_hash
        # this is a one level deep deep_merge
        merged_hash = {}
        highest_value_found = {}
        COMPONENTS_AS_SYMBOLS.each do |component|
          hash = instance_variable_get(:"@#{component}")
          next unless hash.is_a?(Hash)
          hash.each do |key, value|
            merged_hash[key] ||= self.class.new
            merged_hash[key].instance_variable_set(:"@#{component}", value)
            highest_value_found[key] = value
          end
        end
        # we need to expose scalars as undecorated scalars (esp. nil, true, false)
        highest_value_found.each do |key, value|
          next if highest_value_found[key].is_a?(Hash) || highest_value_found[key].is_a?(Array)
          merged_hash[key] = highest_value_found[key]
        end
        merged_hash
      end

      def merged_array
        automatic_array || override_array || normal_array || default_array
      end

      def default_array
        return nil unless DEFAULT_COMPONENTS_AS_SYMBOLS.any? do |component|
          send(component).is_a?(Array)
        end
        # this is a one level deep deep_merge
        default_array = []
        DEFAULT_COMPONENTS_AS_SYMBOLS.each do |component|
          array = instance_variable_get(:"@#{component}")
          next unless array.is_a?(Array)
          default_array += array.map do |value|
            if value.is_a?(Hash) || value.is_a?(Array)
              self.class.new( component => value )
            else
              value
            end
          end
        end
        default_array
      end

      def normal_array
        return nil unless @normal.is_a?(Array)
        @normal.map do |value|
          if value.is_a?(Hash) || value.is_a?(Array)
            self.class.new( component => value )
          else
            value
          end
        end
      end

      def override_array
        return nil unless OVERRIDE_COMPONENTS_AS_SYMBOLS.any? do |component|
          send(component).is_a?(Array)
        end
        # this is a one level deep deep_merge
        override_array = []
        OVERRIDE_COMPONENTS_AS_SYMBOLS.each do |component|
          array = instance_variable_get(:"@#{component}")
          next unless array.is_a?(Array)
          override_array += array.map do |value|
            if value.is_a?(Hash) || value.is_a?(Array)
              self.class.new( component => value )
            else
              value
            end
          end
        end
        override_array
      end

      def automatic_array
        return nil unless @automatic.is_a?(Array)
        @automatic.map do |value|
          if value.is_a?(Hash) || value.is_a?(Array)
            self.class.new( component => value )
          else
            value
          end
        end
      end

      # @return [Object] value of the highest precedence level
      def highest_precedence
        COMPONENTS.map do |component|
          instance_variable_get(component)
        end.compact.last
      end
    end
  end
end
