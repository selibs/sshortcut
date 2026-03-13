package s.shortcut;

#if macro
import haxe.macro.Expr;
#end
import haxe.Constraints.Function;

@:forward.new
abstract Signal<T:Function>(SignalData<T>) {
	public var count(get, never):Int;

	@:to
	inline function toData():SignalData<T>
		return this;

	macro public function emit(self:Expr, exprs:Array<Expr>)
		return macro @:privateAccess {
			final __self = $self.toData();
			if (__self.i == 0)
				try {
					while (__self.i < __self.slots.length)
						__self.slots[__self.i++]($a{exprs});
					__self.i = 0;
				} catch (e) {
					__self.i = 0;
					throw e;
				}
		}

	@:op(a())
	macro function call(self:Expr, exprs:Array<Expr>)
		return macro $self.emit($a{exprs});

	public function connect(slot:T) {
		if (!this.slots.contains(slot))
			this.slots.push(slot);
		return slot;
	}

	public function disconnect(slot:T) {
		final ind = this.slots.indexOf(slot);
		final r = ind >= 0;
		if (r) {
			if (ind < this.i)
				--this.i;
			this.slots.splice(ind, 1);
		}
		return r;
	}

	inline function get_count():Int
		return this.slots.length;
}

@:allow(s.shortcut.Signal)
private class SignalData<T:Function> {
	var i:Int = 0;
	var slots:Array<T>;

	public function new(?slots:Array<T>) {
		this.slots = slots ?? [];
	}
}
