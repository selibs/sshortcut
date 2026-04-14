package s.shortcut.signals;

#if macro
import haxe.macro.Expr;
#end
import haxe.Constraints.Function;

@:forward.new
abstract KeySignal<K, T:Function>(KeySignalData<K, T>) {
	public var count(get, never):Int;

	@:to
	inline function toData():KeySignalData<K, T>
		return this;

	macro public function emit(self:Expr, exprs:Array<Expr>) {
		var e = [];
		var key = exprs.shift();
		e.push(macro final __self = $self.toData());
		e.push(macro final __key = $key);
		for (i in 0...exprs.length) {
			var name = "__a" + i;
			e.push(macro final $name = ${exprs[i]});
			exprs[i] = macro @:pos(exprs[i].pos) $i{name};
		}
		e.push(macro if (__self.i == 0) try {
			while (__self.i < __self.slots.length) {
				final __slot = __self.slots[__self.i++];
				if (__slot.key == __key)
					__slot.f($a{exprs});
			}
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

	public function stop() {
		if (this.i != 0)
			this.i = this.slots.length;
	}

	public function connect(key:K, slot:T, pos:Int = 0):T {
		var ind = 0;
		while (ind < this.slots.length)
			if (this.slots[ind++].f == slot)
				return slot;

		pos = pos > count ? count : (pos < 0 ? {var p = count + pos + 1; p < 0 ? 0 : p;} : pos);
		if (pos < this.i)
			++this.i;
		this.slots.insert(pos, {key: key, f: slot});

		return slot;
	}

	public function disconnect(slot:T):Bool {
		var ind = -1;
		for (i in 0...this.slots.length)
			if (this.slots[i].f == slot) {
				ind = i;
				break;
			}
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

@:allow(s.shortcut.signals.KeySignal)
private class KeySignalData<K, T:Function> {
	var i:Int = 0;
	var slots:Array<{key:K, f:T}>;

	public function new(?slots:Array<{key:K, f:T}>) {
		this.slots = slots ?? [];
	}
}
