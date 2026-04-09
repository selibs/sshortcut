package s.shortcut;

abstract class AttachedAttribute<T:{private var dirty(default, set):Bool;}> implements s.shortcut.Shortcut {
	final object:T;
	var dirty(default, set):Bool = false;

	public function new(object:T)
		this.object = object;

	function flush() {}

	function set_dirty(value:Bool) @:privateAccess {
		if (value && !object.dirty)
			object.dirty = true;
		return dirty = value;
	}
}
