package s.shortcut;

abstract class AttachedAttribute<T:AttributeOwner> implements s.shortcut.Shortcut {
	final object:T;
	var dirty(default, set):Bool = false;

	public function new(object:T)
		this.object = object;

	function flush() {}

	function set_dirty(value:Bool) {
		if (value)
			object.markDirty();
		return dirty = value;
	}
}
