package s.shortcut;

#if macro
import haxe.ds.StringMap;
import haxe.macro.Type;
import haxe.macro.Expr;
import haxe.macro.Context;
import haxe.macro.Compiler;

using StringTools;
using haxe.macro.ExprTools;
using haxe.macro.TypeTools;
using haxe.macro.TypedExprTools;

private typedef TemplateDef = {params:Array<TypeParameter>, fields:Array<Field>};
private typedef MixinDef = {> TemplateDef, decl:Array<Field>};

#end
class ShortcutMacro {
	#if macro
	static var mixins:StringMap<MixinDef> = new StringMap();
	static var builtTemplates:StringMap<TypePath> = new StringMap();
	@:persistent static var templates:StringMap<TemplateDef> = new StringMap();

	public static function init() {
		for (m in [
			":mixin",
			":template",
			":readonly",
			":writeonly",
			":alias",
			":inject",
			":cache",
			":attr",
			":attr.group",
			":signal",
			":slot",
			"connect",
			"track",
			"bind"
		])
			Compiler.registerCustomMetadata({metadata: m, doc: "short"}, "cut");
		Compiler.addGlobalMetadata("", "@:build(s.shortcut.ShortcutMacro.mixinBuild())");
	}

	public static function mixinBuild():Array<Field> {
		var fields = Context.getBuildFields();
		var ref = Context.getLocalClass();
		if (ref == null)
			return fields;
		var cls = ref.get();
		if (cls.meta.has(":template"))
			return registerTemplate(ref, cls, fields);
		applyMixin(fields, cls);
		return fields;
	}

	public static function build() {
		var fields = Context.getBuildFields();

		var slots = [];
		var signals:Map<String, {isStatic:Bool, slots:Array<Expr>}> = [];

		var constructor = null;

		var flush = null;
		var classFlush = null;
		var attrs = [];
		var classAttrs = [];

		var invalid = null;
		var classInvalid = null;
		var cache = [];
		var classCache = [];

		var superConstructor = null;
		var superFlush = null;
		var superInvalid = null;

		function findFields(cls:ClassType) {
			if (cls == null)
				return;
			if (superConstructor == null)
				superConstructor = cls.constructor?.get();
			if (superFlush == null)
				superFlush = cls.findField("flush");
			if (superInvalid == null)
				superInvalid = cls.findField("invalidateCache");
			findFields(cls.superClass?.t.get());
		}
		var cls = Context.getLocalClass()?.get();
		if (cls != null)
			findFields(cls.superClass?.t.get());

		var gen = cls != null && !cls.isExtern && !cls.isInterface;

		for (field in fields.copy()) {
			switch field.kind {
				case FFun(f):
					// f.expr = buildConnect(f.expr);
					if (constructor == null && field.name == "new")
						constructor = f.expr;
					if (flush == null && field.name == "flush")
						flush = f.expr;
					if (classFlush == null && field.name == "flushClass")
						classFlush = f.expr;
					if (invalid == null && field.name == "invalidateCache")
						invalid = f.expr;
					if (classInvalid == null && field.name == "invalidateClassCache")
						classInvalid = f.expr;
				default:
					// case FVar(t, e):
					// 	field.kind = FVar(t, buildConnect(e));
					// case FProp(get, set, t, e):
					// 	field.kind = FProp(get, set, t, buildConnect(e));
			}
			var meta = field.meta ?? [];
			for (m in meta.copy()) {
				var parts = m.name.split(".");
				switch parts[0] {
					case ":readonly":
						buildAccess(gen, field, true, false);
					case ":writeonly":
						buildAccess(gen, field, false, true);
					case ":alias":
						buildAlias(gen, fields, field);
					case ":inject":
						if (m.params != null && m.params.length > 0)
							buildInject(gen, fields, field, m.params);
					case ":signal":
						var key = null;
						if (m.params != null && m.params.length > 0)
							if (m.params.length == 1)
								switch m.params[0].expr {
									case EConst(CIdent(s)):
										key = s;
									default:
										Context.error("Invalid expression", m.params[0].pos);
								}
							else
								Context.error("Expected only 1 key argument name", m.pos);
						buildSignal(gen, fields, field, signals, key);
					case ":slot":
						slots.push({field: field, signals: m.params, pos: m.pos});
					case ":attr":
						var name = field.name;
						var params = m.params ?? [];
						if (params.length > 0) {
							if (params.length == 1)
								switch params[0].expr {
									case EConst(CIdent(s)):
										name = s;
									default:
										Context.error("Expected name", m.pos);
								}
							else
								Context.error("Expected exactly 1 name", m.pos);
						}
						if (parts[1] == "group")
							attrs.push(macro @:privateAccess $i{name}.flush());
						else {
							var attr = buildAttr(gen, fields, field, name, signals);
							if (attr != null)
								if (field.access.contains(AStatic))
									classAttrs.push(attr);
								else
									attrs.push(attr);
						}
					case ":cache":
						var c = buildCache(gen, fields, field);
						if (c != null)
							if (field.access.contains(AStatic))
								classCache.push(c);
							else
								cache.push(c);
					default:
						continue;
				}
				meta.remove(m);
			}
		}

		buildSlots(gen, fields, slots, signals, constructor, superConstructor);
		buildFlush(gen, fields, flush, classFlush, superFlush != null, attrs, classAttrs);
		buildInvalidate(gen, fields, invalid, classInvalid, superInvalid != null, cache, classCache);

		return fields;
	}

	public static function buildTemplate():ComplexType {
		var local = switch Context.getLocalType() {
			case TInst(t, params): {shell: t, args: params};
			case _: Context.error("Class expected", Context.currentPos());
		}
		var shell = local.shell;
		var args = local.args;
		var shellCls = shell.get();
		if (args.length == 0)
			Context.error("Base class type parameter expected", shellCls.pos);

		var baseRef = expectClass(args[0]);
		var base = baseRef.get();
		var shellKey = shell.toString();
		var key = shellKey + "<" + args.map(typeKey).join(",") + ">";
		var path = builtTemplates.get(key);

		if (path == null) {
			var template = getTemplate(shell, shellCls);
			if (template == null)
				Context.error("Template definition not found", shellCls.pos);

			path = {pack: shellCls.pack, name: templateName(shellCls, key, args)};
			if (!typeExists(path))
				Context.defineType({
					pack: path.pack,
					name: path.name,
					kind: TDClass(expectPath(args[0])),
					params: [],
					fields: remapFields(template.fields, template.params, args),
					pos: base.pos
				}, base.module);
			builtTemplates.set(key, path);
		}

		return TPath(path);
	}

	static function buildConnect(expr:Expr):Expr {
		function connect(expr:Expr) {
			static var i = 0;

			var con:Array<{name:String, signal:Expr, expr:Expr}> = [];

			function replaceConnect(expr:Expr) {
				var c = connect(expr);
				if (c.connect != null)
					con = con.concat(c.connect);
				return c.expr;
			}

			if (expr == null)
				return {connect: con, expr: expr};

			switch expr.expr {
				case EFunction(kind, f):
					f.expr = buildConnect(f.expr);
				case EBlock(exprs):
					expr.expr = EBlock(exprs.map(buildConnect));
				case EFor(it, expr):
					expr.expr = EFor(replaceConnect(it), buildConnect(expr));
				case EIf(econd, eif, eelse):
					expr.expr = EIf(replaceConnect(econd), buildConnect(eif), buildConnect(eelse));
				case EWhile(econd, e, normalWhile):
					expr.expr = EWhile(replaceConnect(econd), buildConnect(e), normalWhile);
				case ESwitch(e, cases, edef):
					expr.expr = ESwitch(replaceConnect(e), cases.map(c -> {
						values: c.values,
						guard: c.guard,
						expr: buildConnect(c.expr)
					}), buildConnect(edef));
				case ETry(e, catches):
					expr.expr = ETry(replaceConnect(e), catches.map(c -> {
						name: c.name,
						type: c.type,
						expr: buildConnect(c.expr)
					}));
				case ETernary(econd, eif, eelse):
					expr.expr = ETernary(replaceConnect(econd), buildConnect(eif), buildConnect(eelse));
				case EMeta(s, e):
					var signal = switch s.name {
						case "connect":
							e;
						case "track":
							makeIdent(e, "Dirty");
						case "bind":
							makeIdent(e, "Changed");
						default:
							expr = expr.map(replaceConnect);
					}
					if (signal != null) {
						expr.expr = e.expr;
						con.push({name: "__c" + i++, signal: signal, expr: expr});
					}
				default:
					expr = expr.map(replaceConnect);
			}
			return {connect: con, expr: expr}
		}

		function rename(expr:Expr, target:Expr, name:String)
			return expr == target ? macro @:pos(expr.pos) $i{name} : expr.map(e -> rename(e, target, name));

		// var con = connect(expr);
		// if (con.connect.length > 0) {
		// 	var exprs = [];
		// 	for (c in con.connect) {
		// 		var name = c.name;
		// 		var signal = c.signal;
		// 		exprs.push(macro $signal.connect($name -> ${rename(expr, c.expr, name)}));
		// 	}
		// 	return macro @:pos(expr.pos) $b{exprs};
		// }

		// return con.expr;
		return expr;
	}

	static function buildAccess(gen:Bool, field:Field, read:Bool, write:Bool) {
		switch field.kind {
			case FVar(t, e):
				field.kind = FProp(read ? "default" : "never", write ? "default" : "never", t, e);
			case FProp(get, set, t, e):
				if (!read)
					get = "never";
				if (!write)
					set = "never";
				field.kind = FProp(get, set, t, e);
			case FFun(f):
				Context.error("Can't change function access", field.pos);
		}
	}

	static function buildAlias(gen:Bool, fields:Array<Field>, field:Field) {
		switch field.kind {
			case FVar(t, e):
				field.kind = FProp("get", "set", t, e);
				buildAlias(gen, fields, field);
			case FProp(get, set, t, e):
				if (e == null)
					Context.error("Alias expression expected", field.pos);
				if (t == null)
					Context.error("Alias must be type-hinted", field.pos);

				field.kind = FProp(get == "default" ? "get" : get, set == "default" ? "set" : set, t, null);
				injectProp(gen, fields, field, r -> macro return $e, r -> macro return $e = $r, true);
				if (!field.access.contains(AExtern))
					field.access.push(AExtern);
			case FFun(f):
				Context.error("Functions can't be aliases", field.pos);
		}
	}

	static function buildInject(gen:Bool, fields:Array<Field>, field:Field, injections:Array<Expr>) {
		switch field.kind {
			case FVar(t, e):
				field.kind = FProp("default", "set", t, e);
				buildInject(gen, fields, field, injections);
			case FProp(get, set, t, e):
				if (set != "null" && set != "set" && set != "default")
					Context.error('Can\'t inject property with $set write access', field.pos);
				var canRead = get != "never";
				var setterName = "set_" + field.name;
				for (f in fields)
					if (f.name == setterName) {
						buildInject(gen, fields, f, injections);
						return;
					}

				var setter = {
					name: setterName,
					access: [APrivate].concat(field.access.contains(AStatic) ? [AStatic] : []),
					kind: FFun({
						args: [{name: "value", type: t}],
						expr: gen ? (canRead ? macro return $i{field.name} = value : macro return value) : null
					}),
					pos: field.pos
				}
				fields.push(setter);
				buildInject(gen, fields, setter, injections);
			case FFun(f):
				var injection = macro $b{injections};
				if (gen)
					f.expr = f.expr != null ? injectReturn(f.expr, injection) : injection;
		}
	}

	static function buildSignal(gen:Bool, fields:Array<Field>, field:Field, signals:Map<String, {isStatic:Bool, slots:Array<Expr>}>, ?key:String) {
		var slots = [];
		var slotsExpr = {
			expr: EArrayDecl(slots),
			pos: field.pos
		}
		switch field.kind {
			case FFun(f):
				if (f.expr != null)
					Context.warning("Signals can't have expressions", f.expr.pos);

				var keyT = null;
				var slotArgs = [];
				for (a in f.args) {
					if (a.type == null)
						Context.error("Signal arguments must be type-hinted", field.pos);
					if (a.name == key) {
						keyT = a.type;
						continue;
					}
					var named = TNamed(a.name, a.type);
					slotArgs.push(a.opt ? TOptional(named) : named);
				}
				var slotT:ComplexType = TFunction(slotArgs, macro :Void);

				if (keyT == null)
					field.kind = FProp("default", "never", macro :s.shortcut.signals.Signal<$slotT>,
						gen ? macro new s.shortcut.signals.Signal($slotsExpr) : null);
				else
					field.kind = FProp("default", "never", macro :s.shortcut.signals.KeySignal<$keyT, $slotT>,
						gen ? macro new s.shortcut.signals.KeySignal($slotsExpr) : null);

				// sugar
				var name = field.name.charAt(0).toUpperCase() + field.name.substr(1);
				for (f in ["on" => "", "off" => "dis"].keyValueIterator()) {
					var m = f.value + "connect";
					var args = [{name: "slot", type: slotT}];
					var params = [macro slot];
					if (f.key == "on" && key != null) {
						args.unshift({name: key, type: keyT});
						params.unshift(macro $i{key});
					}

					fields.push({
						name: f.key + name,
						access: field.access,
						kind: FFun({
							args: args,
							ret: f.key == "on" ? slotT : macro :Bool,
							expr: gen ? (macro return $i{field.name}.$m($a{params})) : null
						}),
						pos: field.pos
					});
				}
			case FVar(t, _), FProp(_, _, t, _):
				var signalName = field.name + "Changed";
				injectProp(gen, fields, field, r -> macro {$i{signalName}($r); return $r;});
				var signal:Field = {
					access: field.access,
					name: signalName,
					kind: FFun({args: [{name: field.name, type: t}]}),
					pos: field.pos
				};
				fields.push(signal);
				buildSignal(gen, fields, signal, signals);
		}

		signals.set(field.name, {
			isStatic: field.access.contains(AStatic),
			slots: slots
		});
	}

	static function buildAttr(gen:Bool, fields:Array<Field>, field:Field, name:String, signals:Map<String, {isStatic:Bool, slots:Array<Expr>}>) {
		if (!gen)
			return null;

		// marker
		var markerName = name + "IsDirty";
		var markerRef = macro $i{markerName};
		var marker = macro if (!$markerRef) $markerRef = true;
		var hasMarker = false;
		for (f in fields)
			if (f.name == markerName) {
				hasMarker = true;
				break;
			}
		if (!hasMarker)
			fields.push({
				name: markerName,
				access: field.access.contains(AStatic) ? [AStatic] : [],
				kind: FProp("default", "null", macro :Bool, macro false),
				pos: field.pos
			});

		var refName = field.name.charAt(0).toUpperCase() + field.name.substr(1);
		var valName, signalName, signalType;
		switch field.kind {
			case FVar(t, e), FProp(_, _, t, e):
				valName = field.name;
				signalName = valName + "Dirty";
				signalType = t;
				var canRead = switch field.kind {
					case FVar(_, _): true;
					case FProp(get, _, _, _): get != "never";
					default: false;
				};
				if (canRead)
					marker = macro if (__prev__ != $i{field.name}) $marker;
				injectProp(gen, fields, field, null, r -> macro {$marker; return $r;});
			case FFun(f):
				if (gen && f.expr == null)
					Context.error("Can't track function with no expression", field.pos);
				if (f.ret == null)
					Context.error("Missing return type", field.pos);
				// cache
				valName = field.name + "Cached";
				signalName = field.name + "Called";
				signalType = f.ret;
				fields.push({
					name: valName,
					access: field.access.contains(AStatic) ? [AStatic] : [],
					kind: FProp("default", "null"),
					pos: field.pos
				});
				if (gen)
					f.expr = injectReturn(f.expr, macro {$i{valName} = __r; $marker;});
		}

		return macro $markerRef = false;
	}

	static function buildSlots(gen:Bool, fields:Array<Field>, slots:Array<{field:Field, signals:Array<Expr>, pos:Position}>,
			signals:Map<String, {isStatic:Bool, slots:Array<Expr>}>, constructor:Expr, superConstructor:ClassField) {
		function extractConnect(expr:Expr) {
			return switch expr.expr {
				case EConst(CIdent(s)):
					{signal: s, key: null};
				case ECall(e, params):
					if (params.length != 1)
						Context.error("Expected exactly 1 key parameter", expr.pos);
					{signal: extractConnect(e).signal, key: params[0]};
				case EField(e, field, kind):
					{signal: extractConnect(e).signal + "." + field, key: null};
				default:
					Context.error("Invalid expression. Signal name expected", expr.pos);
					null;
			}
		}

		if (slots == null || slots.length == 0)
			return;

		if (!gen)
			return;

		if (constructor == null) {
			var isPublic = false, args = [];
			if (superConstructor != null)
				switch superConstructor.expr().expr {
					case TFunction(tfunc):
						var values = [];
						for (a in tfunc.args) {
							var v = a.v;
							var e = a.value;
							values.push(macro $i{v.name});
							args.push(({
								name: v.name,
								type: v.t.toComplexType(),
								opt: e != null,
								value: e != null ? switch e.expr {
									case TConst(TInt(i)): macro $v{i};
									case TConst(TFloat(s)): macro $v{Std.parseFloat(s)};
									case TConst(TString(s)): macro $v{s};
									case TConst(TBool(b)): macro $v{b};
									case TConst(TNull): macro null;
									case TConst(TThis): macro this;
									case TConst(TSuper): macro super;
									default:
										Context.error("Constant value expected", e.pos);
								} : null
							} : FunctionArg));
						}
						isPublic = superConstructor.isPublic;
						constructor = macro super($a{values});
					default:
						Context.error("Constructor must be function", superConstructor.pos);
				}
			else {
				isPublic = false;
				constructor = macro null;
				args = [];
			}

			fields.push({
				name: "new",
				access: isPublic ? [APublic] : [],
				kind: FFun({
					args: args,
					expr: constructor
				}),
				pos: Context.currentPos()
			});
		}

		var exprs = [{expr: constructor.expr, pos: constructor.pos}];
		for (slot in slots) {
			if (slot.signals == null || slot.signals.length == 0)
				Context.error("Expected signal names", slot.pos);
			for (signal in slot.signals) {
				var con = extractConnect(signal);
				var sig = signals.get(con.signal);
				if (sig != null && sig.isStatic && slot.field.access.contains(AStatic))
					if (con.key == null)
						sig.slots.push(macro $i{slot.field.name});
					else
						sig.slots.push(macro {key: ${con.key}, f: $i{slot.field.name}});
				else {
					if (con.key == null)
						exprs.push(macro $signal.connect(@:pos(slot.field.pos) $i{slot.field.name}));
					else
						exprs.push(macro $signal.connect(${con.key}, @:pos(slot.field.pos) $i{slot.field.name}));
				}
			}
		}

		constructor.expr = EBlock(exprs);
	}

	static function buildFlush(gen:Bool, fields:Array<Field>, flush:Expr, classFlush:Expr, overrides:Bool, attrs:Array<Expr>, classAttrs:Array<Expr>) {
		if (!gen)
			return;

		if (attrs.length > 0) {
			attrs.unshift(flush ?? (overrides ? macro super.flush() : macro null));
			fields.push({
				name: "flush",
				access: overrides ? [AOverride] : [],
				kind: FFun({
					args: [],
					expr: macro $b{attrs}
				}),
				pos: Context.currentPos()
			});
		}

		if (classAttrs.length > 0)
			classAttrs.unshift(classFlush ?? macro null);
		if (classAttrs.length > 0)
			fields.push({
				name: "flushClass",
				access: [AStatic],
				kind: FFun({
					args: [],
					expr: macro $b{classAttrs}
				}),
				pos: Context.currentPos()
			});
	}

	static function buildCache(gen:Bool, fields:Array<Field>, field:Field) {
		if (!gen)
			return null;

		var cacheName = field.name + "Cached";
		switch field.kind {
			case FVar(t, _), FProp(_, _, t, _):
				fields.push({
					name: cacheName,
					access: field.access,
					kind: FProp("default", "null", t, macro $i{field.name}),
					pos: field.pos
				});
			case FFun(f):
				Context.error("Can't cache function", field.pos);
		}
		return macro if ($i{cacheName} != $i{field.name}) $i{cacheName} = $i{field.name};
	}

	static function buildInvalidate(gen:Bool, fields:Array<Field>, invalid:Expr, classInvalid:Expr, overrides:Bool, cache:Array<Expr>, classCache:Array<Expr>) {
		if (!gen)
			return;

		if (cache.length > 0) {
			cache.unshift(invalid ?? (overrides ? macro super.invalidateCache() : macro null));
			fields.push({
				name: "invalidateCache",
				access: overrides ? [AOverride] : [],
				kind: FFun({
					args: [],
					expr: macro $b{cache}
				}),
				pos: Context.currentPos()
			});
		}

		if (classCache.length > 0)
			classCache.unshift(classInvalid ?? macro null);
		if (classCache.length > 0)
			fields.push({
				name: "invalidateClassCache",
				access: [AStatic],
				kind: FFun({
					args: [],
					expr: macro $b{classCache}
				}),
				pos: Context.currentPos()
			});
	}

	static function registerTemplate(ref:Ref<ClassType>, cls:ClassType, fields:Array<Field>) {
		if (cls.params.length == 0)
			Context.error("Base class type parameter expected", cls.pos);
		cls.meta.extract(":genericBuild");
		cls.meta.add(":genericBuild", [macro s.shortcut.ShortcutMacro.buildTemplate()], cls.pos);
		templates.set(ref.toString(), {params: cls.params, fields: copyFields(fields)});
		return [for (field in fields) stubField(field)];
	}

	static function getTemplate(shell:Ref<ClassType>, cls:ClassType):TemplateDef {
		var key = shell.toString();
		var template = templates.get(key);
		if (template == null) {
			Context.getModule(cls.module);
			template = templates.get(key);
		}
		return template;
	}

	static function applyMixin(fields:Array<Field>, cls:ClassType) {
		var inherited = inheritMixins(cls);
		var path = typePath(cls);

		if (cls.meta.has(":mixin") && cls.isInterface) {
			var decl = copyFields(inherited.decl);
			var stored = inherited.fields;
			for (field in fields.copy()) {
				var original = copyField(field);
				if (field.name == "new") {
					fields.remove(field);
					continue;
				}
				normalizeMixinField(field);
				decl.push(copyField(field));
				if (hasImplementation(original))
					stored.push(original);
			}
			mixins.set(path, {params: cls.params, decl: decl, fields: stored});
			return;
		}

		if (cls.isInterface) {
			mixins.set(path, {
				params: cls.params,
				decl: inherited.decl.concat(copyFields(fields)),
				fields: inherited.fields
			});
			return;
		}

		addMissingFields(fields, inherited.fields);
	}

	static function inheritMixins(cls:ClassType):{decl:Array<Field>, fields:Array<Field>} {
		var decl = [];
		var fields = [];
		for (iface in cls.interfaces) {
			var mixin = mixins.get(typePath(iface.t.get()));
			if (mixin == null)
				continue;
			decl = decl.concat(remapFields(mixin.decl, mixin.params, iface.params));
			fields = fields.concat(remapFields(mixin.fields, mixin.params, iface.params));
		}
		return {decl: decl, fields: fields};
	}

	static function normalizeMixinField(field:Field) {
		if (!field.access.contains(APrivate) && !field.access.contains(APublic))
			field.access.push(APrivate);
		#if eval
		field.access.remove(AExtern);
		#end
		clearField(field);
	}

	static function addMissingFields(fields:Array<Field>, extra:Array<Field>) {
		var names = new StringMap<Bool>();
		for (field in fields)
			names.set(field.name, true);
		for (field in extra)
			if (!names.exists(field.name)) {
				names.set(field.name, true);
				fields.push(field);
			}
	}

	static function fieldExists(cls:ClassType, name:String) {
		return findField(cls, name) != null;
	}

	static function findField(cls:ClassType, name:String) {
		if (cls == null)
			return null;
		if (name == "new") {
			var field = cls.constructor?.get();
			if (field != null)
				return field;
		}
		var field = cls.findField(name);
		if (field != null)
			return field;
		return findField(cls.superClass?.t.get(), name);
	}

	static function remapFields(fields:Array<Field>, types:Array<TypeParameter>, params:Array<Type>)
		return [for (field in fields) mapField(copyField(field), types, params)];

	static function copyFields(fields:Array<Field>)
		return [for (field in fields) copyField(field)];

	static function typePath(cls:ClassType) {
		var parts = cls.module.split(".");
		if (parts[parts.length - 1] != cls.name)
			parts.push(cls.name);
		return parts.join(".");
	}

	static function stubField(field:Field) {
		field.access.remove(AOverride);
		field.kind = switch field.kind {
			case FVar(t, _): FVar(t, macro null);
			case FProp(get, set, t, _): FProp(get, set, t, macro null);
			case FFun(f):
				f.expr = macro null;
				f.ret = macro :Void;
				FFun(f);
		}
		return field;
	}

	static function clearField(field:Field) {
		field.access.remove(AInline);
		field.kind = switch field.kind {
			case FVar(t, e): FVar(inferType(e, t, field.pos), null);
			case FProp(get, set, t, e): FProp(get, set, inferType(e, t, field.pos), null);
			case FFun(f):
				f.expr = null;
				FFun(f);
		}
		return field;
	}

	static function mapField(field:Field, types:Array<TypeParameter>, params:Array<Type>) {
		field.kind = switch field.kind {
			case FVar(t, e): FVar(mapType(t, types, params), mapExpr(e, types, params));
			case FProp(get, set, t, e): FProp(get, set, mapType(t, types, params), mapExpr(e, types, params));
			case FFun(f): FFun(mapFunction(f, types, params));
		}
		return field;
	}

	static function injectProp(gen:Bool, fields:Array<Field>, field:Field, ?getExpr:Expr->Expr, ?setExpr:Expr->Expr, isExtern:Bool = false) {
		function pushAccessor(name:String, fun:Function) {
			var access = [APrivate];
			if (field.access.contains(AStatic))
				access.push(AStatic);
			if (isExtern) {
				access.push(AExtern);
				access.push(AInline);
			}
			fields.push({
				access: access,
				name: name,
				kind: FFun(fun),
				pos: field.pos
			});
		}

		switch field.kind {
			case FVar(t, e):
				field.kind = FProp(getExpr != null ? "get" : "default", setExpr != null ? "set" : "default", t, e);
				injectProp(gen, fields, field, getExpr, setExpr);
			case FProp(get, set, t, e):
				var isVar = false;
				for (m in field.meta)
					if (m.name == ":isVar") {
						isVar = true;
						break;
					}
				if (!isVar)
					isVar = get == "default" || set == "default";

				if (get != "get" && get != "null" && get != "default")
					getExpr = null;

				if (set != "set" && set != "null" && set != "default")
					setExpr = null;

				field.kind = FProp(get, set, t, e);

				var getterName = "get_" + field.name;
				var setterName = "set_" + field.name;
				var getter:Function = null;
				var setter:Function = null;
				for (f in fields)
					switch f.kind {
						case FFun(fn):
							if (f.name == getterName || f.name == setterName) {
								if (gen && fn.expr == null)
									Context.error("Function requires a body", f.pos);
								if (f.name == getterName)
									getter = fn;
								else
									setter = fn;
							}
						default: continue;
					}

				if (getExpr != null) {
					if (getter == null) {
						getter = {
							args: [],
							ret: t,
							expr: gen && isVar ? macro return $i{field.name} : null}
						pushAccessor(getterName, getter);
					}
					if (gen)
						getter.expr = getter.expr != null ? replaceReturn(getter.expr, getExpr) : getExpr(null);
				}

				if (setExpr != null) {
					if (setter == null) {
						setter = {
							args: [{name: "value", type: t}],
							ret: t,
							expr: gen ? (isVar ? macro return $i{field.name} = value : macro return value) : null
						}
						pushAccessor(setterName, setter);
					}
					if (gen) {
						if (get != "never") {
							setter.expr = macro {
								var __prev__ = $i{field.name};
								${setter.expr};
							}
						}
						setter.expr = replaceReturn(setter.expr, setExpr);
					}
				}
			case _:
				Context.error("Property expected", field.pos);
		}
	}

	static function injectReturn(e1:Expr, e2:Expr):Expr {
		return replaceReturn(e1, r -> macro {$e2; ${r == null ?macro return:macro return $r}});
	}

	static function replaceReturn(e1:Expr, e2:Expr->Expr) {
		var replaced = false;

		function replace(expr:Expr) {
			return switch expr.expr {
				case EFunction(_, _): expr;
				case EReturn(v):
					replaced = true;
					if (v == null) e2(null) else macro {
						final __r = $v;
						${e2(macro __r)};
					}
				default: expr.map(replace);
			}
		}

		var expr = replace(e1);
		if (replaced)
			return expr;

		return macro {
			final __r = $e1;
			${e2(macro __r)};
		};
	}

	static function mapFunction(f:Function, types:Array<TypeParameter>, params:Array<Type>):Function
		return {
			args: [for (arg in f.args) mapArg(arg, types, params)],
			ret: mapType(f.ret, types, params),
			expr: mapExpr(f.expr, types, params),
			params: mapTypeParams(f.params, types, params)
		}

	static function mapArg(arg:FunctionArg, types:Array<TypeParameter>, params:Array<Type>):FunctionArg
		return {
			name: arg.name,
			opt: arg.opt,
			type: mapType(arg.type, types, params),
			value: mapExpr(arg.value, types, params),
			meta: copyMeta(arg.meta)
		}

	static function mapExpr(expr:Expr, types:Array<TypeParameter>, params:Array<Type>):Expr {
		if (expr == null)
			return null;

		var mapped = expr.map(e -> mapExpr(e, types, params));
		return switch mapped.expr {
			case EVars(vars):
				at(mapped.pos, EVars([
					for (v in vars)
						{
							name: v.name,
							namePos: v.namePos,
							type: mapType(v.type, types, params),
							expr: v.expr,
							isFinal: v.isFinal,
							isStatic: v.isStatic,
							meta: copyMeta(v.meta)
						}
				]));
			case EFunction(kind, f):
				at(mapped.pos, EFunction(kind, mapFunction(f, types, params)));
			case ETry(e, catches):
				at(mapped.pos, ETry(e, [
					for (c in catches)
						{
							name: c.name,
							type: mapType(c.type, types, params),
							expr: c.expr
						}
				]));
			case ECheckType(e, t):
				at(mapped.pos, ECheckType(e, mapType(t, types, params)));
			case ECast(e, t):
				at(mapped.pos, ECast(e, t == null ? null : mapType(t, types, params)));
			case _:
				mapped;
		}
	}

	static function at(pos:Position, expr:ExprDef):Expr
		return {expr: expr, pos: pos};

	static function mapType(type:ComplexType, types:Array<TypeParameter>, params:Array<Type>):ComplexType
		return type == null ? null : switch type {
			case TPath(p):
				var direct = remapTypeParam(p, types, params);
				direct != null ? direct : TPath({
					pack: p.pack,
					name: p.name,
					sub: p.sub,
					params: [
						for (tp in p.params)
							switch tp {
								case TPType(t):
									TPType(mapType(t, types, params));
								case _:
									tp;
							}
					]
				});
			case TFunction(args, ret):
				TFunction(args.map(t -> mapType(t, types, params)), mapType(ret, types, params));
			case TParent(t):
				TParent(mapType(t, types, params));
			case TOptional(t):
				TOptional(mapType(t, types, params));
			case _:
				type;
		}

	static function remapTypeParam(path:TypePath, types:Array<TypeParameter>, params:Array<Type>) {
		if (path.pack.length != 0 || path.sub != null || path.params.length != 0)
			return null;
		for (i in 0...types.length)
			if (path.name == types[i].name)
				return params[i].toComplexType();
		return null;
	}

	static function mapTypeParams(paramsDecl:Array<TypeParamDecl>, types:Array<TypeParameter>, params:Array<Type>):Array<TypeParamDecl>
		return (paramsDecl ?? []).map(p -> ({
			name: p.name,
			constraints: p.constraints == null ? null : [for (t in p.constraints) mapType(t, types, params)],
			defaultType: p.defaultType == null ? null : mapType(p.defaultType, types, params),
			params: mapTypeParams(p.params, types, params),
			meta: copyMeta(p.meta)
		}));

	static function hasImplementation(field:Field)
		return !field.access.contains(AExtern) && switch field.kind {
			case FFun(f): f.expr != null;
			case _: true;
		} static function expectClass(type:Type)

		return switch Context.follow(type) {
			case TInst(t, _): t;
			case _: Context.error("Class expected", Context.currentPos());
		}

	static function expectPath(type:Type):TypePath
		return switch type.toComplexType() {
			case TPath(p): p;
			case _: Context.error("Class expected", Context.currentPos());
		}

	static function typeExists(path:TypePath) {
		try {
			Context.getType(fullTypeName(path));
			return true;
		} catch (_)
			return false;
	}

	static function fullTypeName(path:TypePath) {
		var parts = path.pack.copy();
		parts.push(path.name);
		if (path.sub != null)
			parts.push(path.sub);
		return parts.join(".");
	}

	static function typeKey(type:Type):String
		return switch Context.follow(type) {
			case TInst(t, params): typeNameKey(t.get().module, params);
			case TType(t, params): typeNameKey(t.get().module, params);
			case TAbstract(t, params): typeNameKey(t.get().module, params);
			case TEnum(t, params): typeNameKey(t.get().module, params);
			case TFun(args, ret): "(" + args.map(a -> typeKey(a.t)).join(",") + ")->" + typeKey(ret);
			case TAnonymous(_): type.toString();
			case TDynamic(t): t == null ? "Dynamic" : "Dynamic<" + typeKey(t) + ">";
			case TLazy(f): typeKey(f());
			case TMono(r): r.get() == null ? "Unknown" : typeKey(r.get());
		}

	static function typeNameKey(name:String, params:Array<Type>)
		return params.length == 0 ? name : name + "<" + params.map(typeKey).join(",") + ">";

	static function templateName(cls:ClassType, key:String, params:Array<Type>) {
		var base = typePath(cls).split(".").join("_") + "_" + params.map(typeNamePart).join("_");
		return sanitizeName(base) + "__" + hashString(key);
	}

	static function typeNamePart(type:Type):String
		return switch Context.follow(type) {
			case TInst(t, params): pathNamePart(t.get().pack, t.get().name, null, params);
			case TType(t, params): pathNamePart(t.get().pack, t.get().name, null, params);
			case TAbstract(t, params): pathNamePart(t.get().pack, t.get().name, null, params);
			case TEnum(t, params): pathNamePart(t.get().pack, t.get().name, null, params);
			case TFun(args, ret): "Fn_" + args.map(a -> typeNamePart(a.t)).join("_") + "_To_" + typeNamePart(ret);
			case TAnonymous(_): "Anon";
			case TDynamic(t): t == null ? "Dynamic" : "Dynamic_" + typeNamePart(t);
			case TLazy(f): typeNamePart(f());
			case TMono(r): r.get() == null ? "Unknown" : typeNamePart(r.get());
		}

	static function pathNamePart(pack:Array<String>, name:String, sub:String, params:Array<Type>) {
		var parts = (pack ?? []).copy();
		parts.push(name);
		if (sub != null)
			parts.push(sub);
		var value = parts.join("_");
		return params.length == 0 ? value : value + "_" + params.map(typeNamePart).join("_");
	}

	static function sanitizeName(name:String) {
		var out = new StringBuf();
		for (i in 0...name.length) {
			var c = name.charCodeAt(i);
			var ok = c >= "0".code && c <= "9".code || c >= "A".code && c <= "Z".code || c >= "a".code && c <= "z".code || c == "_".code;
			out.addChar(ok ? c : "_".code);
		}
		var value = out.toString();
		if (value.length == 0)
			return "Template";

		var first = value.charCodeAt(0);
		if (first >= "a".code && first <= "z".code)
			return String.fromCharCode(first - ("a".code - "A".code)) + value.substr(1);
		if (first >= "A".code && first <= "Z".code)
			return value;
		return "T_" + value;
	}

	static function hashString(s:String) {
		var h = 0;
		for (i in 0...s.length)
			h = (h * 223 + s.charCodeAt(i)) & 0x7fffffff;
		return StringTools.hex(h, 8).toLowerCase();
	}

	static function inferType(expr:Expr, type:ComplexType, pos:Position):ComplexType {
		if (type != null)
			return type;
		if (expr == null)
			Context.error("This field must be type-hinted", pos);
		try {
			return Context.typeExpr(expr).t.toComplexType();
		} catch (e)
			Context.error(e.message, pos);
		return null;
	}

	static function copyField(field:Field):Field
		return {
			name: field.name,
			doc: field.doc,
			access: (field.access ?? []).copy(),
			kind: switch field.kind {
				case FVar(t, e): FVar(t, copyExpr(e));
				case FProp(get, set, t, e): FProp(get, set, t, copyExpr(e));
				case FFun(f): FFun(copyFunction(f));
			},
			pos: field.pos,
			meta: copyMeta(field.meta)
		}

	static function copyFunction(f:Function):Function
		return {
			args: [for (arg in f.args) copyArg(arg)],
			ret: f.ret,
			expr: copyExpr(f.expr),
			params: copyTypeParams(f.params)
		}

	static function copyArg(arg:FunctionArg):FunctionArg
		return {
			name: arg.name,
			opt: arg.opt,
			type: arg.type,
			value: copyExpr(arg.value),
			meta: copyMeta(arg.meta)
		}

	static function copyMeta(meta:Metadata):Metadata
		return (meta ?? []).map(m -> ({
			name: m.name,
			params: (m.params ?? []).map(copyExpr),
			pos: m.pos
		}));

	static function copyTypeParams(params:Array<TypeParamDecl>):Array<TypeParamDecl>
		return (params ?? []).map(p -> ({
			name: p.name,
			constraints: (p.constraints ?? []).copy(),
			defaultType: p.defaultType,
			params: copyTypeParams(p.params),
			meta: copyMeta(p.meta)
		}));

	static function copyExpr(expr:Expr):Expr
		return expr == null ? null : macro @:pos(expr.pos) ${expr.map(copyExpr)};

	static function makeIdent(expr:Expr, ?add:String) {
		add = add ?? "";
		return switch expr.expr {
			case EConst(CIdent(s)):
				macro @:pos(expr.pos) $i{s + add};
			case EField(e, field, kind):
				field += add;
				macro @:pos(expr.pos) ${makeIdent(e)}.$field;
			default:
				Context.error("Identifier expected", expr.pos);
				null;
		}
	}
	#end
}
