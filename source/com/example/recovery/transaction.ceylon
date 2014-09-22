//import com.example.recovery { DummyXAResource }
import ceylon.transaction.tm { TM, getTM }

import java.lang { System { setProperty }, Thread { currentThread, threadSleep = sleep }, Class, ClassLoader }
import ceylon.interop.java { javaClassFromInstance }

import javax.sql { DataSource }
import ceylon.collection { HashMap, MutableMap, HashSet, MutableSet }
import ceylon.dbc { Sql, newConnectionFromDataSource }

import javax.transaction {
    TransactionManager,
    Transaction,
    UserTransaction,
    Status { status_no_transaction = \iSTATUS_NO_TRANSACTION, status_active = \iSTATUS_ACTIVE }
}

import javax.transaction.xa {
    XAResource
}

import org.h2.jdbcx {JdbcDataSource}

TM tm = getTM();
String dbloc = "jdbc:h2:tmp/ceylondb";
variable Integer nextKey = 5;

//{String+} dsBindings2 = { "postgresql", "oracle_thin" };
//{String+} dsBindings2 = { "postgresql", "hsqldb" };
{String+} dsBindings = { "h2" };
{String+} dsBindings2 = { "db2", "postgresql" };

MutableMap<String,Sql> getSqlHelper({String+} bindings) {
    MutableMap<String,Sql> sqlMap = HashMap<String,Sql>();

    for (dsName in bindings) {
        DataSource? ds = getXADataSource(dsName);
        assert (is DataSource ds);
        Sql sql = Sql(newConnectionFromDataSource(ds));
        sqlMap.put(dsName, sql);
        initDb(sql);
        print("db ``dsName`` registered");
    }

    return sqlMap;
}

DataSource? getXADataSource(String binding) {
    Object? ds = tm.getJndiServer().lookup(binding);

    if (is DataSource ds) {
        return ds;
    } else {
        return null;
    }
}

Boolean updateTable(Sql sq, String dml, Boolean ignoreErrors) {
    try {
        sq.Update(dml).execute();

        return true;
    } catch (Exception ex) {
        print("``dml`` error: ``ex.message``");
        if (!ignoreErrors) {
            throw ex;
        }

        return false;
    }
}

void initDb(Sql sql) {
// TODO h2 is put in read only state until all pending branches are complete (ie we should wait for a tm recovery
// pass to complete them first
    updateTable(sql, "DROP TABLE CEYLONKV", true);
    updateTable(sql, "CREATE TABLE CEYLONKV (rkey VARCHAR(255) not NULL, val VARCHAR(255), PRIMARY KEY ( rkey ))", true);
      sql.Update("DELETE FROM CEYLONKV").execute();
}


// insert two values into each of the requested dbs
Integer insertTable(Collection<Sql> dbs) {
    for (sql in dbs) {
        print("inserting key ``nextKey`` using ds ``sql``");
        sql.Update("INSERT INTO CEYLONKV(rkey,val) VALUES (?, ?)").execute( "k" + nextKey.string, "v" + nextKey.string);
    }
    nextKey = nextKey + 1;
    for (sql in dbs) {
        print("inserting key ``nextKey`` using ds ``sql``");
        sql.Update("INSERT INTO CEYLONKV(rkey,val) VALUES (?, ?)").execute( "k" + nextKey.string, "v" + nextKey.string);
    }
    nextKey = nextKey + 1;

    return 2;
}

void transactionalWork(Boolean doInTxn, Boolean commit, MutableMap<String,Sql> sqlMap) {
    UserTransaction? transaction;

    if (doInTxn) {
        transaction = tm.beginTransaction();
        enlistDummyXAResources();
    } else {
        transaction = null;
    }

    MutableMap<String,Integer> counts = getRowCounts(sqlMap);
    Integer rows = insertTable(sqlMap.items);

    if (exists transaction) {
        if (commit) {
            transaction.commit();
            checkRowCounts(counts, getRowCounts(sqlMap), rows);
        } else {
            transaction.rollback();
            checkRowCounts(counts, getRowCounts(sqlMap), 0);
            nextKey = nextKey - 2;
        }
    } else {
        checkRowCounts(counts, getRowCounts(sqlMap), rows);
    }
}

MutableMap<String,Integer> getRowCounts(MutableMap<String,Sql> sqlMap) {
    MutableMap<String,Integer> values = HashMap<String,Integer>();

    for (entry in sqlMap) {
      Sql sql = entry.item;
      Integer? count = sql.Select("SELECT COUNT(*) FROM CEYLONKV").singleValue<Integer>();

      assert (exists count);
      values.put (entry.key, count);
    }

    return values;
}

void checkRowCounts(MutableMap<String,Integer> prev, MutableMap<String,Integer> curr, Integer delta) {
    for (entry in prev) {
        Integer? c = curr[entry.key];
        if (exists c) {
            assert(entry.item + delta == c);
        }
    }
}

// Test XA transactions with one resource
void sqlTest1() {
    MutableMap<String,Sql> sqlMap = getSqlHelper(dsBindings);

    // local commit
    transactionalWork(false, true, sqlMap);
    // XA commit
    transactionalWork(true, true, sqlMap);
}

// Test XA transactions with multiple resources
void sqlTest2(Boolean doInTxn) {
    MutableMap<String,Sql> sqlMap = getSqlHelper(dsBindings2);

    // XA abort
    transactionalWork(doInTxn, false, sqlMap);

    // XA commit
    transactionalWork(doInTxn, true, sqlMap);
}

void init() {
    setProperty("com.arjuna.ats.arjuna.objectstore.objectStoreDir", "tmp");
    setProperty("com.arjuna.ats.arjuna.common.ObjectStoreEnvironmentBean.objectStoreDir", "tmp");

    tm.start(false);

    if (tm.isTxnActive()) {
        print("Old transaction still associated with thread");
        throw;
    }

    // programatic method of registering datasources (the alternative is to use a config file
    tm.getJndiServer().registerDriverSpec("org.h2.Driver", "org.h2", "1.3.168", "org.h2.jdbcx.JdbcDataSource");
    tm.getJndiServer().registerDSUrl("h2", "org.h2.Driver", dbloc, "sa", "sa");

//    tm.getJndiServer().registerDriverSpec(
//        "org.postgresql.Driver", "org.jumpmind.symmetric.jdbc.postgresql", "9.2-1002-jdbc4", "org.postgresql.xa.PGXADataSource");
//    tm.getJndiServer().registerDSName(
//        "postgresql", "org.postgresql.Driver", "ceylondb", "localhost", 5432, "sa", "sa");
}

void fini() {
    tm.stop();
}

void enlistDummyXAResources() {
    TransactionManager? transactionManager = tm.getTransactionManager();
    assert (is TransactionManager transactionManager);
    Class<out Object> nbClazz = javaClassFromInstance(transactionManager);

    Transaction txn = transactionManager.transaction;

    DummyXAResource dummyResource1 = DummyXAResource();
    //DummyXAResource dummyResource2 = DummyXAResource();

    txn.enlistResource(dummyResource1);
    //txn.enlistResource(dummyResource2);
}

"The runnable method of the module."
by("Mike Musgrove")
shared void run() {
    init();
 
    MutableMap<String,Sql> sqlMap = getSqlHelper(dsBindings);

    transactionalWork(true, true, sqlMap);

    fini();
}

