module FatJam
  module ActsAsRevisable
    # This module is mixed into the revision and revisable classes.
    # 
    # ==== Callbacks
    # 
    # * +before_branch+ is called on the +Revisable+ or +Revision+ that is 
    #   being branched
    # * +after_branch+ is called on the +Revisable+ or +Revision+ that is 
    #   being branched
    module Common
      def self.included(base) #:nodoc:
        base.send(:extend, ClassMethods)
        
        base.class_inheritable_hash :revisable_after_callback_blocks
        base.revisable_after_callback_blocks = {}
        
        base.class_inheritable_hash :revisable_current_states
        base.revisable_current_states = {}
        
        class << base
          alias_method_chain :instantiate, :revisable
        end

        base.instance_eval do
          define_callbacks :before_branch, :after_branch      
          has_many :branches, :class_name => base.class_name, :foreign_key => :revisable_branched_from_id
          belongs_to :branch_source, :class_name => base.class_name, :foreign_key => :revisable_branched_from_id
          after_save :execute_blocks_after_save
          disable_revisable_scope :branch_source
        end        
      end
            
      # Executes the blocks stored in an accessor after a save.
      def execute_blocks_after_save #:nodoc:
        return unless revisable_after_callback_blocks[:save]
        revisable_after_callback_blocks[:save].each do |block|
          block.call
        end
        revisable_after_callback_blocks.delete(:save)
      end
      
      # Stores a block for later execution after a given callback.
      # The parameter +key+ is the callback the block should be 
      # executed after.
      def execute_after(key, &block) #:nodoc:
        return unless block_given?
        revisable_after_callback_blocks[key] ||= []
        revisable_after_callback_blocks[key] << block
      end
            
      # Branch the +Revisable+ or +Revision+ and return the new 
      # +revisable+ instance. The instance has not been saved yet.
      # 
      # ==== Callbacks
      # * +before_branch+ is called on the +Revisable+ or +Revision+ that is 
      #   being branched
      # * +after_branch+ is called on the +Revisable+ or +Revision+ that is 
      #   being branched
      # * +after_branch_created+ is called on the newly created 
      #   +Revisable+ instance.
      def branch(*args, &block)
        is_branching!
        
        unless run_callbacks(:before_branch) { |r, o| r == false}
          raise ActiveRecord::RecordNotSaved
        end

        options = args.extract_options!
        options[:revisable_branched_from_id] = self.id
        self.class.column_names.each do |col|
          next unless self.class.revisable_should_clone_column? col
          options[col.to_sym] = self[col] unless options.has_key?(col.to_sym)
        end
        
        br = self.class.revisable_class.new(options)
        br.is_branching!
        
        br.execute_after(:save) do
          begin
            run_callbacks(:after_branch)
            br.run_callbacks(:after_branch_created)
          ensure
            br.is_branching!(false)
            is_branching!(false)
          end
        end
        
        block.call(br) if block_given?
        
        br
      end
      
      # Same as #branch except it calls #save! on the new +Revisable+ instance.
      def branch!(*args)
        branch(*args) do |br|
          br.save!
        end
      end
      
      # Globally sets the reverting state of this record.
      def is_branching!(value=true) #:nodoc:
        set_revisable_state(:branching, value)
      end
      
      # Returns true if the _record_ (not just this instance 
      # of the record) is currently being branched.
      def is_branching?
        get_revisable_state(:branching)
      end
      
      # When called on a +Revision+ it returns the original id. When
      # called on a +Revisable+ it returns the id.
      def original_id
        self[:revisable_original_id] || self[:id]
      end
      
      # Globally sets the state for a given record. This is keyed
      # on the primary_key of a saved record or the object_id
      # on a new instance.
      def set_revisable_state(type, value) #:nodoc:
        key = self.read_attribute(self.class.primary_key)
        key = object_id if key.nil?
        revisable_current_states[type] ||= {}
        revisable_current_states[type][key] = value
        revisable_current_states[type].delete(key) unless value
      end
      
      # Returns the state of the given record.
      def get_revisable_state(type) #:nodoc:
        key = self.read_attribute(self.class.primary_key)
        revisable_current_states[type] ||= {}
        revisable_current_states[type][key] || revisable_current_states[type][object_id] || false
      end
      
      # Returns true if the instance is the first revision.
      def first_revision?
        self.revision_number == 1
      end
      
      # Returns true if the instance is the most recent revision.
      def latest_revision?
        self.revision_number == self.current_revision.revision_number
      end
      
      # Returns true if the instance is the current record and not a revision.
      def current_revision?
        self.is_a? self.class.revisable_class
      end
      
      module ClassMethods
        def disable_revisable_scope(*args)
          args.each do |a|            
            class_eval <<-EOT
              def #{a.to_s}_with_open_scope(*args, &block)
                assoc = self.class.reflect_on_association(#{a.inspect})
                models = [self.class]
                
                if [:has_many, :has_one].member? assoc.macro
                  models << (assoc.options[:class_name] ? assoc.options[:class_name] : #{a.inspect}.to_s.singularize.camelize).constantize
                end
                                
                begin
                  models.each {|m| m.scoped_model_enabled = false}
                  #{a.to_s}_without_open_scope(*args, &block).reload
                ensure
                  models.each {|m| m.scoped_model_enabled = true}
                end
              end
            EOT
            alias_method_chain a, :open_scope
          end
        end
        
        # Returns true if the revision should clone the given column.    
        def revisable_should_clone_column?(col) #:nodoc:
          return false if (REVISABLE_SYSTEM_COLUMNS + REVISABLE_UNREVISABLE_COLUMNS).member? col
          true
        end
        
        # acts_as_revisable's override for instantiate so we can
        # return the appropriate type of model based on whether
        # or not the record is the current record.
        def instantiate_with_revisable(record) #:nodoc:
          is_current = columns_hash["revisable_is_current"].type_cast(
                record["revisable_is_current"])

          if (is_current && self == self.revisable_class) || (!is_current && self == self.revision_class)
            return instantiate_without_revisable(record)
          end

          object = if is_current
            self.revisable_class
          else
            self.revision_class
          end.allocate

          object.instance_variable_set("@attributes", record)
          object.instance_variable_set("@attributes_cache", Hash.new)

          if object.respond_to_without_attributes?(:after_find)
            object.send(:callback, :after_find)
          end

          if object.respond_to_without_attributes?(:after_initialize)
            object.send(:callback, :after_initialize)
          end

          object      
        end
      end
    end
  end
end