// Copyright Supranational LLC

#ifndef __PARENT_ITER_T_HPP__
#define __PARENT_ITER_T_HPP__

// Class to iterate through a cached parent graph.

struct parent_iter_t {
  node_id_t _node;
  uint32_t  _parent;
  uint32_t* parent_buf;
  uint32_t* parent_ptr;

  parent_iter_t(node_id_t start) :
    _node(start), _parent(0) {
  }

  // Size in bytes of the parent graph
  static size_t bytes() {
    return NODE_COUNT * PARENT_COUNT * PARENT_SIZE;
  }

  void set_buf(uint32_t* buf) {
    parent_buf = buf;
    parent_ptr = buf;
  }

  void operator ++(int) {
    _parent++;
    parent_ptr++;
    if (_parent == PARENT_COUNT) {
      _node++;
      _parent = 0;
    }
    // Advance to the next layer
    bool restart = _node.node() == 0 && _parent == 0;
    if (restart) {
      printf("Starting layer %d\n", _node.layer());
      parent_ptr = parent_buf;
    }
  }
  node_id_t operator *() {
    uint32_t layer = (_node.layer() == 0 ? 0 :
                      (is_prev_layer() ? _node.layer() - 1 : _node.layer()));
    node_id_t parent_id(layer, *parent_ptr);
    return parent_id;
  }
  uint64_t id() {
    return _node.id();
  }
  uint32_t node() {
    return _node.node();
  }
  uint32_t layer() {
    return _node.layer();
  }
  uint32_t parent() {
    return _parent;
  }  

  node_id_t get_node() {
    return _node;
  }
  size_t get_parent() {
    return _parent;
  }
  bool is_prev_layer() {
    return get_parent() >= PARENT_COUNT_BASE;
  }
};

#endif
