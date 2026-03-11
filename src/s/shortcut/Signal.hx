package s.shortcut;

#if macro
import haxe.macro.Expr;
#end
import haxe.Constraints.Function;

@:forward.new
class Signal<T:Function> {
	var i:Int = 0;
	var slots:Array<T>;

	public var count(get, never):Int;

	public function new(?slots:Array<T>) {
		this.slots = slots ?? [];
	}

	macro public function emit(self:Expr, exprs:Array<Expr>)
		return macro @:privateAccess
			if ($self.i == 0) try {
				while ($self.i < $self.count)
					$self.slots[$self.i++]($a{exprs});
				$self.i = 0;
			} catch (e) {
				$self.i = 0;
				throw e;
			}

	public function connect(slot:T) {
		if (!slots.contains(slot))
			slots.push(slot);
		return slot;
	}

	public function disconnect(slot:T) {
		final ind = slots.indexOf(slot);
		final r = ind >= 0;
		if (r) {
			if (ind < i)
				--i;
			slots.splice(ind, 1);
		}
		return r;
	}

	inline function get_count():Int
		return slots.length;
}
