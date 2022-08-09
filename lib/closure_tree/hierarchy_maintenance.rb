require 'active_support/concern'

module ClosureTree
  module HierarchyMaintenance
    extend ActiveSupport::Concern

    included do
      validate :_ct_validate
      before_save :_ct_before_save
      after_save :_ct_after_save
      around_destroy :_ct_around_destroy
    end

    def _ct_skip_cycle_detection!
      @_ct_skip_cycle_detection = true
    end

    def _ct_skip_sort_order_maintenance!
      @_ct_skip_sort_order_maintenance = true
    end

    def _ct_validate
      if !(defined? @_ct_skip_cycle_detection) &&
        !new_record? && # don't validate for cycles if we're a new record
        changes[_ct.parent_column_name] && # don't validate for cycles if we didn't change our parent
        parent.present? && # don't validate if we're root
        parent.self_and_ancestors.include?(self) # < this is expensive :\
        errors.add(_ct.parent_column_sym, I18n.t('closure_tree.loop_error', default: 'You cannot add an ancestor as a descendant'))
      end
    end

    def _ct_before_save
      @was_new_record = new_record?
      true # don't cancel the save
    end

    def _ct_after_save
      if public_send(:saved_changes)[_ct.parent_column_name] || @was_new_record
        rebuild!
      end
      if public_send(:saved_changes)[_ct.parent_column_name] && !@was_new_record
        # Resetting the ancestral collections addresses
        # https://github.com/mceachen/closure_tree/issues/68
        ancestor_hierarchies.reload
        self_and_ancestors.reload
      end
      @was_new_record = false # we aren't new anymore.
      @_ct_skip_sort_order_maintenance = false # only skip once.
      true # don't cancel anything.
    end

    def _ct_around_destroy
      _ct.with_advisory_lock(self) do
        delete_references([id])

        yield
      end
    end

    def rebuild!
      _ct.with_advisory_lock(self) do
        parent_nodes = parent_nodes(NodeRelation.new(id, send(_ct.parent_column_sym)))
        children_nodes = children_nodes([NodeRelation.new(id, nil)])

        delete_references([id] + children_nodes.map(&:reference))

        relations = build_hierarchy(parent_nodes, children_nodes).map do |ancestor_id, descendant_id, generations|
          {
            ancestor_id: ancestor_id,
            descendant_id: descendant_id,
            generations: generations
          }
        end

        return if relations.empty?

        reorder_siblings
        hierarchy_class.insert_all(relations)
        reorder_children
      end
    end

    def delete_references(ids)
      quoted_ids = ids.map { |id| _ct.quoted_value(id) }.join(',')
      sql = <<-SQL.squish
        DELETE FROM #{_ct.quoted_hierarchy_table_name}
        WHERE ancestor_id IN (#{quoted_ids})
        OR descendant_id IN (#{quoted_ids})
      SQL

      _ct.connection.execute(sql)
    end

    module ClassMethods
      # Rebuilds the hierarchy table based on the parent_id column in the database.
      # Note that the hierarchy table will be truncated.
      def rebuild!
        _ct.with_advisory_lock do
          cleanup!
          roots.find_each(&:rebuild!) # roots just uses the parent_id column, so this is safe.
        end
        nil
      end

      def cleanup!
        hierarchy_table = hierarchy_class.arel_table

        [:descendant_id, :ancestor_id].each do |foreign_key|
          alias_name = foreign_key.to_s.split('_').first + "s"
          alias_table = Arel::Table.new(table_name).alias(alias_name)
          arel_join = hierarchy_table.join(alias_table, Arel::Nodes::OuterJoin)
                                     .on(alias_table[primary_key].eq(hierarchy_table[foreign_key]))
                                     .join_sources

          lonely_childs = hierarchy_class.joins(arel_join).where(alias_table[primary_key].eq(nil))
          ids = lonely_childs.pluck(foreign_key)

          hierarchy_class.where(hierarchy_table[foreign_key].in(ids)).delete_all
        end
      end
    end

    private

    def reorder_children
      _ct_reorder_children if _ct.order_is_numeric? && children.present?
    end

    def reorder_siblings
      return unless _ct.order_is_numeric? && !@_ct_skip_sort_order_maintenance

      _ct_reorder_prior_siblings_if_parent_changed
      _ct_reorder_siblings
    end

    def build_hierarchy(parent_nodes, children_nodes)
      HierarchyBuilder.new(
        parent_nodes,
        children_nodes,
        NodeRelation.new(id, send(_ct.parent_column_sym))
      ).build
    end

    def parent_nodes(node)
      parent_relation = get_parent_relation(node)

      return [] if parent_relation.nil?

      parent = node_from(parent_relation)
      [parent] + parent_nodes(parent)
    end

    def get_parent_relation(node)
      return nil if node.parent_reference.nil?

      results = get_relations_where("#{_ct.primary_key_column.name} = #{_ct.quoted_value(node.parent_reference)}")

      return nil if results.empty?

      results.first
    end

    def get_relations_where(where_expression)
      _ct.connection.execute(
        <<-SQL.squish
          SELECT #{_ct.primary_key_column.name}, #{_ct.quoted_parent_column_name} 
          FROM #{_ct.quoted_table_name} 
          WHERE #{where_expression}
        SQL
      ).to_a
    end

    def children_nodes(nodes)
      results = get_relations_where(
        "#{_ct.quoted_parent_column_name} IN (#{nodes.map { |node| _ct.quoted_value(node.reference) }.join(',')})"
      )

      return [] if results.empty?

      children = results.map { |result| node_from(result) }
      children + children_nodes(children)
    end

    def node_from(relation)
      NodeRelation.from_query_result(_ct, relation)
    end
  end
end
