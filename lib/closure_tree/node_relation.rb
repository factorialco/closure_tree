module ClosureTree
  class NodeRelation
    def self.from_query_result(ct_support, result)
      if result.is_a?(Array)
        reference, parent_reference = result
      else
        reference = result[ct_support.primary_key_column.name]
        parent_reference = result[ct_support.parent_column_name]
      end

      new(reference, parent_reference)
    end

    def initialize(reference, parent_reference)
      @reference = reference
      @parent_reference = parent_reference
    end

    attr_reader :reference, :parent_reference
  end
end
