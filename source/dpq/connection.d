///
module dpq.connection;

//import derelict.pq.pq;
import libpq.libpq;

import dpq.exception;
import dpq.result;
import dpq.value;
import dpq.attributes;
import dpq.querybuilder;
import dpq.meta;
import dpq.prepared;
import dpq.smartptr;
import dpq.serialisation;

import dpq.serialisers.array;
import dpq.serialisers.composite;


import std.string;
import libpq.libpq;
import std.conv : to;
import std.traits;
import std.typecons;


version(unittest)
{
	import std.stdio;
	Connection c;
}

/**
	Represents the PostgreSQL connection and allows executing queries on it.

	Examples:
	-------------
	auto conn = Connection("host=localhost dbname=testdb user=testuser");
	//conn.exec ...
	-------------
*/
struct Connection
{
	private alias ConnectionPtr = SmartPointer!(PGconn*, PQfinish);

	private ConnectionPtr _connection;
	private PreparedStatement[string] _prepared;

	/**
		Connection constructor

		Params:
			connString = connection string

		See Also:
			http://www.postgresql.org/docs/9.3/static/libpq-connect.html#LIBPQ-CONNSTRING
	*/
	this(string connString)
	{
		char* err;
		auto opts = PQconninfoParse(cast(char*)connString.toStringz, &err);

		if (err != null)
			throw new DPQException(err.fromStringz.to!string);

		_connection = new ConnectionPtr(PQconnectdb(connString.toStringz));

		if (status != CONNECTION_OK)
			throw new DPQException(errorMessage);

		_dpqLastConnection = &this;
	}

	unittest
	{
		c = Connection("host=127.0.0.1 dbname=test user=test");
		writeln(" * Database connection with connection string");
		assert(c.status == CONNECTION_OK);
	}

	/** 
		Close the connection manually
	*/
	void close()
	{
		_connection.clear();
	}

	@property const(ConnStatusType) status()
	{
		return PQstatus(_connection);
	}

	/** Returns the name of the database currently selected */
	@property const(string) db()
	{
		return PQdb(_connection).to!string;
	}

	/** Returns the name of the current user */
	@property const(string) user()
	{
		return PQuser(_connection).to!string;
	}

	/// ditto, but password
	@property const(string) password()
	{
		return PQpass(_connection).to!string;
	}

	/// ditto, but host
	@property const(string) host()
	{
		return PQhost(_connection).to!string;
	}

	/// ditto, but port
	@property const(ushort) port()
	{
		return PQport(_connection).fromStringz.to!ushort;
	}

	/**
		Executes the given string directly

		Throws on fatal query errors like bad syntax.
		WARNING: Only returns textual values!!!

		Examples:
		----------------
		Connection conn; // An established connection

		conn.exec("CREATE TABLE IF NOT EXISTS test_table");
		----------------
	*/
	Result exec(string command)
	{
		PGresult* res = PQexec(_connection, cast(const char*)command.toStringz);
		return Result(res);
	}

	unittest
	{
		auto res = c.exec("SELECT 1::INT4 AS int4, 2::INT8 AS some_long");
		writeln(" * exec for selecting INT4 and INT8");
		assert(res.rows == 1);
		assert(res.columns == 2);

		auto r = res[0];
		assert(r[0].as!string == "1");
		assert(r[1].as!string == "2");

		writeln(" * Row opIndex(int) and opIndex(string) equality ");
		assert(r[0] == r["int4"]);
		assert(r[1] == r["some_long"]);

	}

	/// ditto, async
	bool send(string command)
	{
		return PQsendQuery(_connection, cast(const char*)command.toStringz) == 1;
	}

	/**
		Executes the given string with given params

		Params should be given as $1, $2, ... $n in the actual command.
		All params are sent in a binary format and should not be escaped.
		If a param's type cannot be inferred, this method will throw an exception,
		in this case, either specify the type using the :: (cast) notation or
		make sure the type can be inferred by PostgreSQL in your query.

		Examples:
		----------------
		Connection conn; // An established connection

		conn.execParams("SELECT $1::string, $2::int, $3::double");
		----------------

		See also:
			http://www.postgresql.org/docs/9.3/static/libpq-exec.html
	*/
	Result execParams(T...)(string command, T params)
	{
		Value[] values;
		foreach(param; params)
			values ~= Value(param);

		return execParams(command, values);
	}


	/// ditty, but async
	void sendParams(T...)(string command, T params)
	{
		Value[] values;
		foreach(param; params)
			values ~= Value(param);

		execParams(command, values, true);
	}

	/// ditto, but taking an array of params, instead of variadic template
	Result execParams(string command, Value[] params, bool async = false)
	{
		const char* cStr = cast(const char*) command.toStringz;

		auto pTypes = params.paramTypes;
		auto pValues = params.paramValues;
		auto pLengths = params.paramLengths;
		auto pFormats = params.paramFormats;

		if (async)
		{
			PQsendQueryParams(
				_connection,
				cStr,
				params.length.to!int,
				pTypes.ptr,
				cast(const(char*)*)pValues.ptr,
				pLengths.ptr,
				pFormats.ptr,
				1);

			return Result(null);
		}
		else
			return Result(PQexecParams(
					_connection, 
					cStr, 
					params.length.to!int,
					pTypes.ptr, 
					cast(const(char*)*)pValues.ptr,
					pLengths.ptr,
					pFormats.ptr,
					1));
	}

	/// ditto, async
	void sendParams(string command, Value[] params)
	{
		execParams(command, params, true);
	}

	unittest
	{
		writeln("\t * execParams");
		writeln("\t\t * Rows and cols");

		// we're not testing value here, specify types in the query to avoid any oid issues
		auto res = c.execParams("SELECT 1::INT4 AS int4, 2::INT8 AS some_long", []);
		assert(res.rows == 1);
		assert(res.columns == 2);

		writeln("\t\t * Static values");
		auto r = res[0];
		assert(r[0].as!int == 1);
		assert(r[1].as!long == 2);

		writeln("\t\t * opIndex(int) and opIndex(string) equality");
		assert(r[0] == r["int4"]);
		assert(r[1] == r["some_long"]);

		int int4 = 1;
		long int8 = 2;
		string str = "foo bar baz";
		float float4 = 3.14;
		double float8 = 3.1415;

		writeln("\t\t * Passed values");
		res = c.execParams(
				"SELECT $1::INT4, $2::INT8, $3::TEXT, $4::FLOAT4, $5::FLOAT8",
				int4,
				int8,
				str,
				float4,
				float8);

		assert(res.rows == 1);
		r = res[0];

		// This should probably be tested by the serialisers, not here.
		assert(r[0].as!int == int4);
		assert(r[1].as!long == int8);
		assert(r[2].as!string == str);
		assert(r[3].as!float == float4);
		assert(r[4].as!double == float8);
	}

	/**
		Returns the last error message

		Examples:
		--------------------
		Connection conn; // An established connection

		writeln(conn.errorMessage);
		--------------------
	 */
	@property string errorMessage()
	{
		return PQerrorMessage(_connection).to!string;
	}

	unittest
	{
		writeln("\t * errorMessage");
		try
		{
			c.execParams("SELECT_BADSYNTAX $1::INT4", 1);
		}
		catch {}

		assert(c.errorMessage.length != 0);
	}

	/**
		Escapes a string, to be used in a query
	 */
	string escapeLiteral(string str)
	{
		const(char)* cStr = str.toStringz;
		auto esc = PQescapeLiteral(_connection, cStr, str.length);

		if (esc == null)
			throw new DPQException("escapeLiteral failed: " ~ this.errorMessage);

		str = esc.fromStringz.dup; // make a copy, escaped data must be freed
		PQfreemem(esc);
		return str;
	}

	/**
		Escapes an identifier (column, function, table name, ...) to be used in a query.
	 */
	string escapeIdentifier(string str)
	{
		const(char)* cStr = str.toStringz;
		auto esc = PQescapeIdentifier(_connection, cStr, str.length);

		if (esc == null)
			throw new DPQException("escapeIdentifier failed: " ~ this.errorMessage);

		str = esc.fromStringz.dup; // make a copy, escaped data must be freed
		PQfreemem(esc);
		return str;
	}


	/**
		Will create the relation and return the queries (foreign key and index creation)
		that still need to be ran, usually after ALL the relations are created.
	 */
	private string[] createRelation(T)()
	{
		alias members = serialisableMembers!T;

		string relName = SerialiserFor!T.nameForType!T;
		string escRelName = escapeIdentifier(relName);

		// A list of columns in the table
		string[] columns;
		// Queries that must be ran after the table is created
		string[] additionalQueries;

		foreach (mName; members)
		{
			// Is there a better way to do this?
			enum member = "T." ~ mName;

			// If the member is a property, typeof will fail with the wront context error
			// so we construct it and then check the type
			static if (is(FunctionTypeOf!(mixin(member)) == function))
				alias MType = RealType!(typeof(mixin("T()." ~ mName)));
			else
				alias MType = RealType!(typeof(mixin(member)));

			alias serialiser = SerialiserFor!MType;

			// The attribute's name
			string attrName = attributeName!(mixin(member));
			string escAttrName = escapeIdentifier(attrName);

			// And the type, the user-specified type overwrites anything else
			static if (hasUDA!(mixin(member), PGTypeAttribute))
				string attrType = getUDAs!(mixin(member), PGTypeAttribute)[0].type;
			else
				string attrType = serialiser.nameForType!MType;

			string attr = escAttrName ~ " " ~ attrType;

			// A type must be created before using it.
			// This could be implemented using serialisers ...
			serialiser.ensureExistence!MType(this);

			static if (hasUDA!(mixin(member), PrimaryKeyAttribute))
				attr ~= " PRIMARY KEY";
			else static if (hasUDA!(mixin(member), ForeignKeyAttribute))
			{
				enum uda = getUDAs!(mixin(member), ForeignKeyAttribute)[0];

				// Create the FK
				additionalQueries ~= 
					`ALTER TABLE %s ADD CONSTRAINT "%s" FOREIGN KEY(%s) REFERENCES %s (%s)`.format(
							escRelName,
							escapeIdentifier("%s_%s_fk_%s".format(relName, attrName, uda.relation)),
							escAttrName,
							escapeIdentifier(uda.relation),
							escapeIdentifier(uda.pkey));

				// Also create an index on the foreign key
				additionalQueries ~= "CREATE INDEX %s ON %s (%s)".format(
						escapeIdentifier("%s_%s_fk_index".format(relName, attrName)),
						escRelName,
						escAttrName);
			}
			else static if (hasUDA!(mixin(member), IndexAttribute))
			{
				enum uda = getUDAs!(mixin(member), IndexAttribute)[0];

				additionalQueries ~= "CREATE%sINDEX %s ON %s (%s)".format(
						uda.unique ? " UNIQUE " : "", 
						escapeIdentifier("%s_%s_fk_index".format(relName, attrName)),
						escRelName,
						escAttrName);
			}

			columns ~= attr;
		}

		// Create the table
		exec("CREATE TABLE IF NOT EXISTS %s (%s)".format(escRelName, columns.join(", ")));

		addOidsFor(relName);

		return additionalQueries;
	}

	package void addOidsFor(string typeName)
	{
		auto r = execParams("SELECT $1::regtype::oid, $2::regtype::oid", typeName, typeName ~ "[]");
		Oid typeOid = r[0][0].as!int;
		Oid arrOid = r[0][1].as!int;

		CompositeTypeSerialiser.addCustomOid(typeName, typeOid);
		ArraySerialiser.addCustomOid(typeOid, arrOid);
	}


	/**
		Generates and runs the DDL from the given structures

		Attributes from dpq.attributes should be used to define
		primary keys, indexes, and relationships.

		A custom type can be specified with the @type attribute.

		Examples:
		-----------------------
		Connection conn; // An established connection
		struct User 
		{
			@serial8 @PKey long id;
			string username;
			byte[] passwordHash;
		};

		struct Article { ... };

		conn.ensureSchema!(User, Article);
		-----------------------
	*/
	void ensureSchema(T...)(bool createType = false)
	{
		import std.stdio;
		string[] additional;

		foreach (Type; T)
			additional ~= createRelation!Type;

		foreach (cmd; additional)
			try { exec(cmd); } catch {} // Horrible, I know, but this just means the constraint/index already exists
	}

	unittest
	{
		// Probably needs more thorough testing, let's assume right now
		// everything is correct if the creating was successful.

		writeln("\t * ensureSchema");
		struct Inner
		{
			string innerStr;
			int innerInt;
		}

		struct TestTable1
		{
			@serial8 @PK long id;
			string str;
			int n;
			Inner inner;
		}

		c.ensureSchema!TestTable1;
		
		auto res = c.execParams(
				"SELECT COUNT(*) FROM pg_catalog.pg_tables WHERE tablename = $1",
				relationName!TestTable1);

		assert(res.rows == 1);
		assert(res[0][0].as!long == 1);

		c.exec("DROP TABLE " ~ relationName!TestTable1);
		c.exec("DROP TYPE \"" ~ relationName!Inner ~ "\" CASCADE");
	}

	/**
		Returns the requested structure or a Nullable null value if no rows are returned

		This method queries for the given structure by its primary key. If no
		primary key can be found, a compile-time error will be generated.

		Examples:
		----------------------
		Connection conn; // An established connection
		struct User
		{
			@serial @PKey int id;
			...
		};

		auto user = conn.findOne!User(1); // will search by the id attribute
		----------------------
	*/
	Nullable!T findOne(T, U)(U id)
	{
		return findOneBy!T(primaryKeyAttributeName!T, id);
	}

	unittest
	{
		writeln("\t * findOne(T)(U id), findOneBy, findOne");
		struct Testy
		{
			@serial @PK int id;
			string foo;
			int bar;
			long baz;
			int[] intArr;
		}

		c.ensureSchema!Testy;

		writeln("\t\t * Null result");
		auto shouldBeNull = c.findOne!Testy(0);
		assert(shouldBeNull.isNull);

		c.exec(
				"INSERT INTO %s (id, foo, bar, baz, %s) VALUES (1, 'somestr', 2, 3, '{1,2,3}')".format(
					relationName!Testy, attributeName!(Testy.intArr)));

		writeln("\t\t * Valid result");
		Testy t = c.findOne!Testy(1);
		assert(t.id == 1, `t.id == 1` );
		assert(t.foo == "somestr", `t.foo == "somestr"`);
		assert(t.bar == 2, `t.bar == 2`);
		assert(t.baz == 3, `t.baz == 3`);
		assert(t.intArr == [1,2,3], `t.intArr == [1,2,3]`);

		writeln("\t\t * findOne with custom filter");
		Testy t2 = c.findOne!Testy("id = $1", 1);
		assert(t == t2);

		c.exec("DROP TABLE " ~ relationName!Testy);
	}

	/**
		Returns the requested structure, searches by the given column name
		with the given value
		If not rows are returned, a Nullable null value is returned

		Examples:
		----------------------
		Connection conn; // An established connection
		struct User
		{
			@serial @PKey int id;
			...
		};

		auto user = conn.findOneBy!User("id", 1); // will search by "id"
		----------------------
	*/
	Nullable!T findOneBy(T, U)(string col, U val)
	{
		import std.stdio;

		auto members = AttributeList!T;

		QueryBuilder qb;
		qb.select(members)
			.from(relationName!T)
			.where(col, val)
			.limit(1);

		auto q = qb.query(this);

		auto r = q.run();
		if (r.rows == 0)
			return Nullable!T.init;

		//return T();
		
		auto res = deserialise!T(r[0]);
		return Nullable!T(res);
	}
	
	/**
		Returns the requested structure, searches by the specified filter
		with given params

		The filter is not further escaped, so programmer needs to make sure
		not to properly escape or enclose reserved keywords (like user -> "user")
		so PostgreSQL can understand them.

		If not rows are returned, a Nullable null value is returned

		Examples:
		----------------------
		Connection conn; // An established connection
		struct User
		{
			@serial @PKey int id;
			string username;
			int posts;
		};

		auto user = conn.findOne!User("username = $1 OR posts > $2", "foo", 42);
		if (!user.isNull)
		{
			... // do something
		}
		----------------------
	*/
	Nullable!T findOne(T, U...)(string filter, U vals)
	{
		QueryBuilder qb;
		qb.select(AttributeList!T)
			.from(relationName!T)
			.where(filter)
			.limit(1);

		auto q = qb.query(this);
		auto r = q.run(vals);

		if (r.rows == 0)
			return Nullable!T.init;

		auto res = deserialise!T(r[0]);
		return Nullable!T(res);
	}

	/**
		Returns an array of the specified type, filtered with the given filter and
		params

		If no rows are returned by PostgreSQL, an empty array is returned.

		Examples:
		----------------------
		Connection conn; // An established connection
		struct User
		{
			@serial @PKey int id;
			string username;
			int posts;
		};

		auto users = conn.find!User("username = $1 OR posts > $2", "foo", 42);
		foreach (u; users)
		{
			... // do something
		}
		----------------------
	*/
	T[] find(T, U...)(string filter = "", U vals = U.init)
	{
		QueryBuilder qb;
		qb.select(AttributeList!T)
			.from(relationName!T)
			.where(filter);

		auto q = qb.query(this);

		T[] res;
		foreach (r; q.run(vals))
			res ~= deserialise!T(r);

		return res;
	}

	unittest
	{
		writeln("\t * find");

		@relation("find_test")
		struct Test
		{
			@serial @PK int id;
			@attr("my_n") int n;
		}

		c.ensureSchema!Test;

		Test t;
		t.n = 1;

		c.insert(t);
		c.insert(t);
		++t.n;
		c.insert(t);
		c.insert(t);
		c.insert(t);

		Test[] ts = c.find!Test("my_n = $1", 1);
		assert(ts.length == 2);
		ts = c.find!Test("my_n > 0");
		assert(ts.length == 5);
		ts = c.find!Test("false");
		assert(ts.length == 0);

		c.exec("DROP TABLE find_test");
	}

	/**
		Updates records filtered by the filter string, setting the values
		as specified in the update string. Both should be SQL-syntax

		Useful when updating just a single or a bunch of values in the table, or
		when setting the values relatively to their current value.

		Params:
			filter = the SQL filter string
			update = the SQL update string
			vals   = values to be used in the query

		Examples:
		----------------
		Connection c; // an established connection
		struct User { int id; int posts ...}
		c.update!User("id = $1", "posts = posts + $2", 123, 1);
		----------------
	 */
	int update(T, U...)(string filter, string update, U vals)
	{
		QueryBuilder qb;
		qb.update(relationName!T)
			.set(update)
			.where(filter);

		auto r = qb.query(this).run(vals);
		return r.rows;
	}

	unittest
	{
		writeln("\t * update");

		@relation("update_test")
		struct Test
		{
			@serial @PK int id;
			int n;
		}

		c.ensureSchema!Test;

		Test t;
		t.n = 5;
		c.insert(t);

		int nUpdates = c.update!Test("n = $1", "n = $2", 5, 123);
		assert(nUpdates == 1, `nUpdates == 1`);

		t = c.findOneBy!Test("n", 123);
		assert(t.n == 123, `t.n == 123`);

		writeln("\t\t * async");
		c.updateAsync!Test("n = $1", "n = $2", 123, 6);
		auto r = c.nextResult();

		assert(r.rows == 1);
		assert(!c.findOneBy!Test("n", 6).isNull);

		c.exec("DROP TABLE update_test");
	}

	/// ditto, async
	void updateAsync(T, U...)(string filter, string update, U vals)
	{
		QueryBuilder qb;
		qb.update(relationName!T)
			.set(update)
			.where(filter);

		qb.query(this).runAsync(vals);
	}

	/**
		Similar to above update, but instead of acceptign a filter and and update string,
		always filters by the PK and updates with absolute values from the updates AA.

		Params:
			id      = the value of the relation's PK to filter by
			updates = an AA, mapping column name to the new value to be set for the column
			async   = optionally send this query async

		Examples:
		------------------
			Connection c; // en established connection
			struct User { @PK int id; int x; string y }
			c.update!User(1, [
					"x": Value(2),
					"y": Value("Hello there")]);
		------------------
	 */
	int update(T, U)(U id, Value[string] updates, bool async = false)
	{
		QueryBuilder qb;

		qb.update(relationName!T)
			.set(updates)
			.where(primaryKeyAttributeName!T, id);

		auto q = qb.query(this);

		if (async)
		{
			q.runAsync();
			return -1;
		}

		auto r = q.run();
		return r.rows;
	}

	unittest
	{
		writeln("\t * update with AA updates");

		@relation("update_aa_test")
		struct Test
		{
			@serial @PK int id;
			int n;
		}
		c.ensureSchema!Test;

		Test t;
		t.n = 1;
		c.insert(t);

		int rows = c.update!Test(1, ["n": Value(2)]);
		assert(rows == 1, `r.rows == 1`);

		c.exec("DROP TABLE update_aa_test");
	}

	// ditto, but async
	void updateAsync(T, U)(U id, Value[string] updates)
	{
		update!T(id, updates, true);
	}

	/**
		Similar to above, but accepts the whole structure as an update param.
		Filters by the PK, updates ALL the values in the filtered rows.

		Params:
			id = value of the relation's PK to filter by
			updates = the structure that will provide values for the UPDATE
			asnyc = whether the query should be sent async

		Examples:
		------------------
		Connection c; // an established connection
		struct User { @PK int id; int a; int b; }
		c.update(1, myUser);
		------------------
	 */
	int update(T, U)(U id, T updates, bool async = false)
	{
		import dpq.attributes;

		QueryBuilder qb;

		qb.update(relationName!T)
			.where(primaryKeyAttributeName!T, id);

		foreach (m; serialisableMembers!T)
			qb.set(attributeName!(mixin("T." ~ m)), __traits(getMember, updates, m));

		auto q = qb.query(this);
		if (async)
		{
			qb.query(this).runAsync();
			return -1;
		}

		auto r = q.run();
		return r.rows;
	}

	// ditto, async
	void updateAsync(T, U)(U id, T updates)
	{
		update!T(id, updates, true);
	}

	unittest
	{
		writeln("\t * update with object");
		
		@relation("update_object_test")
		struct Test
		{
			@serial @PK int id;
			int n;
		}
		c.ensureSchema!Test;

		Test t;
		t.n = 1;
		t.id = 1; // assumptions <3

		c.insert(t);

		t.n = 2;
		c.update!Test(1, t);
		
		t = c.findOne!Test(1);
		assert(t.n == 2);

		t.n = 3;
		c.updateAsync!Test(1, t);
		auto r = c.nextResult();

		writeln("\t\t * async");
		assert(r.rows == 1);

		c.exec("DROP TABLE update_object_test");
	}

	private void addVals(T, U)(ref QueryBuilder qb, U val)
	{
		if (isAnyNull(val))
			qb.addValue(null);
		else
		{
			foreach (m; serialisableMembers!(NoNullable!T))
			{
				static if (isPK!(T, m) || hasUDA!(mixin("T." ~ m), IgnoreAttribute))
					continue;
				else
					qb.addValue(__traits(getMember, val, m));
			}
		}
	}

	/**
		Inserts the given structure, returning whatever columns are specified by the
		second param as a normal Result.

		Equivalent to specifying RETURNING at the end of the query.

		Examples:
		-------------------
		Connection c; // an established connection
		struct Data { @PK int id, int a; int b; }
		Data myData;
		auto result = c.insert(myData, "id");
		-------------------
	 */
	Result insertR(T)(T val, string ret = "")
	{
		QueryBuilder qb;
		qb.insert(relationName!T, AttributeList!(T, true, true));
		if (ret.length > 0)
			qb.returning(ret);

		addVals!T(qb, val);

		return qb.query(this).run();
	}

	/**
		Inserts the given structure to the DB

		Examples:
		---------------
		Connection c; // An established connection
		struct User {@PK @serial int id; int a }
		User myUser;
		c.insert(myUser);
		---------------
	 */
	bool insert(T)(T val, bool async = false)
	{
		QueryBuilder qb;
		qb.insert(relationName!T, AttributeList!(T, true, true));

		addVals!T(qb, val);

		if (async)
			return qb.query(this).runAsync();

		auto r = qb.query(this).run();
		return r.rows > 0;
	}

	unittest
	{
		writeln("\t * insert");

		@relation("insert_test_inner")
		struct Inner
		{
			int bar;
		}

		@relation("insert_test")
		struct Test
		{
			int n;
			Nullable!int n2;
			Inner foo;
		}
		c.ensureSchema!Test;

		Test t;
		t.n = 1;
		t.n2 = 2;
		t.foo.bar = 2;
		
		auto r = c.insert(t);
		assert(r == true);

		auto r2 = c.insertR(t, "n");
		assert(r2.rows == 1);
		assert(r2[0][0].as!int == t.n);

		Test t2 = c.findOneBy!Test("n", 1);
		assert(t2 == t, t.to!string ~ " != " ~ t2.to!string);

		writeln("\t\t * async");
		t.n = 123;
		t.n2.nullify;
		c.insertAsync(t);
		
		auto res = c.nextResult();
		assert(res.rows == 1);
		t2 = c.findOneBy!Test("n", 123);
		assert(t.n2.isNull);
		assert(t2.n2.isNull);

		c.exec("DROP TABLE insert_test");
		c.exec("DROP TYPE \"%s\" CASCADE".format(relationName!Inner));
	}

	/// ditto, async
	void insertAsync(T)(T val)
	{
		insert(val, true);
	}

	/**
		Deletes the record in the given table, by its PK

		Examples:
		---------------
		Connection c; // An established connection
		struct User {@PK @serial int id; int a }
		c.remove!User(1);
		---------------
	 */
	int remove(T, U)(U id)
	{
		QueryBuilder qb;
		qb.remove!T
			.where(primaryKeyAttributeName!T, id);

		return qb.query(this).run().rows;
	}

	// ditto, async
	bool removeAsync(T, U)(U id)
	{
		QueryBuilder qb;
		qb.remove!T
			.where(primaryKeyAttributeName!T, id);

		return qb.query(this).runAsync() == 1;
	}


	/**
		Deletes rows in the specified relation, filtered by the given filter string and values

		Examples:
		---------------
		Connection c; // An established connection
		struct User { @PK @serial int id; int posts }
		c.remove!User("id > $1 AND posts == $2", 50, 0);
		---------------
	 */
	int remove(T, U...)(string filter, U vals)
	{
		QueryBuilder qb;
		qb.remove!T
			.where(filter);

		foreach (v; vals)
			qb.addValue(v);

		return qb.query(this).run().rows;
	}

	/// ditto, async
	bool removeAsync(T, U...)(string filter, U vals)
	{
		QueryBuilder qb;
		qb.remove!T
			.where(filter);

		foreach (v; vals)
			qb.addValue(v);

		return qb.query(this).runAsync() == 1;
	}

	unittest
	{
		@relation("remove_test")
		struct Test
		{
			@serial @PK int id;
			int n;
		}
		c.ensureSchema!Test;

		foreach (i; 0 .. 10)
			c.insert(Test(0, i));

		writeln("\t * remove(id)");
		int n = c.remove!Test(1);
		assert(n == 1, `n == 1`);


		writeln("\t\t * async");
		c.removeAsync!Test(2);
		auto r = c.nextResult();
		assert(r.rows == 1, `r.rows == 1`);

		writeln("\t * remove(filter, vals...)");
		n = c.remove!Test("id IN($1,$2,$3,$4,$5)", 3, 4, 5, 6, 7);
		assert(n == 5);

		writeln("\t\t * async");
		c.removeAsync!Test("id >= $1", 7);
		r = c.nextResult();
		assert(r.rows == 3);

		c.exec("DROP TABLE remove_test");
	}

	/**
		Returns a count of the rows matching the filter in the specified relation.
		Filter can be empty or not given to select a count of all the rows in the relation.

		Examples:
		---------------
		Connection c; // An established connection
		struct User {@PK @serial int id; int a }
		long nUsers = c.count!User;
		nUsers = c.count!User("id > $1", 123);
		---------------
	 */
	long count(T, U...)(string filter = "", U vals = U.init)
	{
		import dpq.query;
		auto q = Query(this);
		string str = `SELECT COUNT(*) FROM "%s"`.format(relationName!T);

		if (filter.length > 0)
			str ~= " WHERE " ~ filter;

		q = str;
		auto r = q.run(vals);

		return r[0][0].as!long;
	}

	unittest
	{
		writeln("\t * count");

		@relation("test_count")
		struct Test
		{
			@serial @PK int id;
			int n;
		}

		c.ensureSchema!Test;

		Test t;
		c.insert(t);

		assert(c.count!Test == 1, `count == 1`);
		c.insert(t);
		assert(c.count!Test == 2, `count == 2`);

		c.exec("DROP TABLE test_count");
	}

	/**
		Equivalent to calling PQisBusy from libpq. Only useful if you're doing async
		stuff manually.
	 */
	bool isBusy()
	{
		return PQisBusy(_connection) == 1;
	}

	unittest
	{
		writeln("\t * isBusy");

		assert(c.isBusy() == false);

		c.send("SELECT 1::INT");

		// This could fail in theory, but in practice ... fat chance.
		assert(c.isBusy() == true);

		c.nextResult();
		assert(c.isBusy() == false);
	}


	/**
		 Blocks until a result is read, then returns it

		 If no more results remain, a null result will be returned

		 Make sure to call this until a null is returned or just use allResults.
	*/
	Result nextResult()
	{
		PGresult* res = PQgetResult(_connection);
		return Result(res);
	}

	/**
		Calls nextResult until the value returned is null, the returns them
		as an array.
	 */
	Result[] allResults()
	{
		Result[] res;
		
		PGresult* r;
		while ((r = PQgetResult(_connection)) != null)
			res ~= Result(r);

		return res;
	}
	
	/**
		Calls nextResult until null is returned, then retuns only the last non-null result.
	 */
	Result lastResult()
	{
		Result res;

		PGresult* r;
		while ((r = PQgetResult(_connection)) != null)
			res = Result(r);

		return res;
	}

	unittest
	{
		writeln("\t * nextResult");
		auto x = c.nextResult();
		assert(x.isNull);

		int int1 = 1;
		int int2 = 2;

		c.sendParams("SELECT $1", int1);

		// In every way the same as lastResult
		Result r, t;
		while(!(t = c.nextResult()).isNull)
			r = t;

		assert(r.rows == 1);
		assert(r.columns == 1);
		assert(r[0][0].as!int == int1);

		writeln("\t * lastResult");
		c.sendParams("SELECT $1", int2);
		r = c.lastResult();

		assert(r.rows == 1);
		assert(r.columns == 1);
		assert(r[0][0].as!int == int2);
	}

	Result prepare(T...)(string name, string command, T paramTypes)
	{
		Oid[] oids;
		foreach (pType; paramTypes)
			oids ~= pType;

		char* cName = cast(char*) name.toStringz;
		char* cComm = cast(char*) command.toStringz;

		auto p = PreparedStatement(this, name, command, oids);
		_prepared[name] = p;

		return Result(PQprepare(
					_connection,
					cName,
					cComm,
					oids.length.to!int,
					oids.ptr));
	}

	Result execPrepared(string name, Value[] params...)
	{
		char* cStr = cast(char*) name.toStringz;

		return Result(PQexecPrepared(
					_connection,
					cStr,
					params.length.to!int,
					cast(char**) params.paramValues.ptr,
					params.paramLengths.ptr,
					params.paramFormats.ptr,
					1));
	}

	Result execPrepared(T...)(string name, T params)
	{
		Value[] vals;
		foreach (p; params)
			vals ~= Value(p);

		return execPrepared(name, vals);
	}

	bool sendPrepared(string name, Value[] params...)
	{
		char* cStr = cast(char*) name.toStringz;

		return PQsendQueryPrepared(
				_connection,
				cStr,
				params.length.to!int,
				cast(char**) params.paramValues.ptr,
				params.paramLengths.ptr,
				params.paramFormats.ptr,
				1) == 1;
	}

	bool sendPrepared(T...)(string name, T params)
	{
		Value[] vals;
		foreach (p; params)
			vals ~= Value(p);

		return sendPrepared(name, vals);
	}

	unittest
	{
		writeln("\t * prepare");
		// The result of this isn't really all that useful, but as long as it 
		// throws on errors, it kinda is
		c.prepare("prepare_test", "SELECT $1", Type.INT4);

		writeln("\t * execPrepared");
		auto r = c.execPrepared("prepare_test", 1);
		assert(r.rows == 1);
		assert(r[0][0].as!int == 1);

		writeln("\t\t * sendPrepared");
		bool s = c.sendPrepared("prepare_test", 1);
		assert(s);

		r = c.lastResult();
		assert(r.rows == 1);
		assert(r[0][0].as!int == 1);
	}
	
	ref PreparedStatement prepared(string name)
	{
		return _prepared[name];
	}

	ref PreparedStatement opIndex(string name)
	{
		return prepared(name);
	}
}


/**
	Deserialises the given Row to the requested type

	Params:
		T  = (template) type to deserialise into
		r  = Row to deserialise
*/
T deserialise(T)(Row r, string prefix = "")
{
	T res;
	foreach (m; serialisableMembers!T)
	{
		enum member = "T." ~ m;
		enum n = attributeName!(mixin(member));
		alias OType = typeof(mixin(member));
		alias MType = RealType!OType;

		try
		{
			auto x = r[prefix ~ n].as!MType;
			if (!x.isNull)
				__traits(getMember, res, m) = cast(OType) x;
		}
		catch (DPQException e) 
		{
			if (!isInstanceOf!(Nullable, MType))
				throw e;
		}
	}
	return res;
}

/// Hold the last created connection, not to be used outside the library
package Connection* _dpqLastConnection;
