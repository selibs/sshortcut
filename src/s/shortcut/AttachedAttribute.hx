package s.shortcut;

@:nullSafety
abstract class AttachedAttribute<T:AttributeOwner> implements s.shortcut.Shortcut {
	final object:T;
	var dirty(default, set):Bool = false;

	public function new(object:T)
		this.object = object;

	function flush() {}

	function set_dirty(value:Bool) {
		if (value && object != null)
			object.markDirty();
		return dirty = value;
	}
}
