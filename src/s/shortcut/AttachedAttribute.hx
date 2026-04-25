package s.shortcut;

typedef AttachedAttributeOwner = {function markDirty():Void;}

abstract class AttachedAttribute<T:AttachedAttributeOwner> implements s.shortcut.Shortcut {
	var object:T;
	var dirty(default, set):Bool = false;

	public function new(?object:T)
		this.object = object;

	public function markDirty():Void
		dirty = true;

	function flush() {}

	function set_dirty(value:Bool) {
		if (value && object != null)
			object.markDirty();
		return dirty = value;
	}
}
