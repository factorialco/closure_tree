module ClosureTree
  class HierarchyBuilder
    def initialize(root_nodes, child_nodes, self_node)
      @all_nodes = root_nodes + child_nodes + [self_node]
      @tree = all_nodes.each_with_object({}) { |node, tree| build_node(node, tree) }
      @roots = build_roots(root_nodes)
    end

    def build
      hierarchy = tree.fetch(nil, { children: [] }).fetch(:children).flat_map do |id|
        node_hierarchy(id, id, 0)
      end

      without_roots(hierarchy)
    end

    private

    attr_reader :tree, :all_nodes, :roots

    def build_node(node, tree)
      parent_ref = node.parent_reference
      reference = node.reference

      current = tree.fetch(reference) { |key| tree[key] = {} }
      parent = tree.fetch(parent_ref) { |key| tree[key] = {} }
      siblings = parent.fetch(:children) { |key| parent[key] = [] }

      current[:parent] = parent_ref
      siblings.push(reference)

      tree
    end

    def build_roots(root_nodes)
      root_nodes.each_with_object({}) do |node, roots|
        roots[node.reference] = true
        roots
      end
    end

    def node_hierarchy(origin, parent_id, generation, derived: false)
      relations = []

      relations.push([origin, origin, generation]) unless derived

      tree.fetch(parent_id).fetch(:children, []).each do |child_id|
        relations.push([origin, child_id, generation + 1])
        relations.concat(node_hierarchy(origin, child_id, generation + 1, derived: true))
        relations.concat(node_hierarchy(child_id, child_id, 0)) unless derived
      end

      relations
    end

    def without_roots(hierarchy)
      hierarchy.reject { |parent, child, _| root?(parent) && root?(child) }
    end

    def root?(reference)
      roots.key?(reference)
    end
  end
end
