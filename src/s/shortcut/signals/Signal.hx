package s.shortcut.signals;

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

	macro public function emit(self:Expr, exprs:Array<Expr>) {
		var e = [];
		e.push(macro final __self = $self.toData());
		for (i in 0...exprs.length) {
			var name = "__a" + i;
			e.push(macro final $name = ${exprs[i]});
			exprs[i] = macro @:pos(exprs[i].pos) $i{name};
		}
		e.push(macro if (__self.i == 0) try {
			while (__self.i < __self.slots.length)
				__self.slots[__self.i++]($a{exprs});
			__self.i = 0;
		} catch (e) {
			__self.i = 0;
			throw e;
		});
		return macro @:privateAccess $b{e};
	}

	@:op(a())
	macro function call(self:Expr, exprs:Array<Expr>)
		return macro $self.emit($a{exprs});

	public function stop()
		if (this.i != 0)
			this.i = this.slots.length;

	public function connect(slot:T, pos:Int = -1):T {
		final ind = this.slots.indexOf(slot);
		if (ind != -1)
			return slot;

		pos = pos > count ? count : (pos < 0 ? {var p = count + pos + 1; p < 0 ? 0 : p;} : pos);
		if (pos < this.i)
			++this.i;
		this.slots.insert(pos, slot);

		return slot;
	}

	public function disconnect(slot:T):Bool {
		final ind = this.slots.indexOf(slot);
		if (ind >= 0) {
			if (ind < this.i)
				--this.i;
			this.slots.splice(ind, 1);
			return true;
		}
		return false;
	}

	inline function get_count():Int
		return this.slots.length;
}

@:allow(s.shortcut.signals.Signal)
private class SignalData<T:Function> {
	var i:Int = 0;
	var slots:Array<T>;

	public function new(?slots:Array<T>) {
		this.slots = slots ?? [];
	}
}
