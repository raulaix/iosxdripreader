/**
 Copyright (C) 2016  Johan Degraeve
 
 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
 
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/gpl.txt>.
 
 */
package databaseclasses
{
	import flash.data.SQLConnection;
	import flash.data.SQLMode;
	import flash.data.SQLResult;
	import flash.data.SQLStatement;
	import flash.errors.SQLError;
	import flash.events.EventDispatcher;
	import flash.events.SQLErrorEvent;
	import flash.events.SQLEvent;
	import flash.filesystem.File;
	
	import mx.collections.ArrayCollection;
	
	import spark.collections.Sort;
	import spark.collections.SortField;
	
	import Utilities.Trace;
	
	import events.DatabaseEvent;
	
	import model.ModelLocator;
	
	public class Database extends EventDispatcher
	{
		//Actual Database error : 0036
		[ResourceBundle("database")]
		private static var _instance:Database = new Database();
		public static function get instance():Database {
			return _instance;
		}
		
		private static var aConn:SQLConnection;
		private static var sqlStatement:SQLStatement;
		private static var sampleDatabaseFileName:String = "xdripreader-sample.db";;
		private static const dbFileName:String = "xdripreader.db";
		private static var dbFile:File  ;
		private static var xmlFileName:String;
		private static var databaseWasCopiedFromSampleFile:Boolean = true;
		private static const maxDaysToKeepLogfiles:int = 2;
		public static const END_OF_RESULT:String = "END_OF_RESULT";
		private static const debugMode:Boolean = false;
		
		/**
		 * create table to store the bluetooth device name and address<br>
		 * At most one row should be stored
		 */
		private static const CREATE_TABLE_BLUETOOTH_DEVICE:String = "CREATE TABLE IF NOT EXISTS bluetoothdevice (" +
			"bluetoothdevice_id STRING PRIMARY KEY, " + //unique id, used in all tables that will use Google Sync (note that for iOS no google sync will be done for this table because mac address is not visible in iOS. UDID is used as address but this is different for each install
			"name STRING, " +
			"address STRING, " +
			"lastmodifiedtimestamp TIMESTAMP NOT NULL)";
		
		private static const CREATE_TABLE_LOGGING:String = "CREATE TABLE IF NOT EXISTS logging (" +
			"logging_id STRING PRIMARY KEY, " +
			"log STRING, " +
			"logtimestamp TIMESTAMP NOT NULL, " +
			"lastmodifiedtimestamp TIMESTAMP NOT NULL)";
		
		private static const CREATE_TABLE_CALIBRATION_REQUEST:String = "CREATE TABLE IF NOT EXISTS calibrationrequest (" +
			"calibrationrequestid STRING PRIMARY KEY," +
			"requestifabove REAL," +
			"deleted BOOLEAN," +
			"lastmodifiedtimestamp TIMESTAMP NOT NULL," +
			"requestifbelow REAL)";
		
		private static const CREATE_TABLE_CALIBRATION:String = "CREATE TABLE IF NOT EXISTS calibration (" +
			"calibrationid STRING PRIMARY KEY," +
			"lastmodifiedtimestamp TIMESTAMP NOT NULL," +
			"timestamp TIMESTAMP," +
			"sensorAgeAtTimeOfEstimation REAL," +
			"sensorid STRING," +
			"bg REAL," +
			"rawValue REAL," +
			"adjustedRawValue REAL," +
			"sensorConfidence REAL," +
			"slopeConfidence REAL," +
			"rawTimestamp TIMESTAMP," +
			"slope REAL," +
			"intercept REAL," +
			"distanceFromEstimate REAL," +
			"estimateRawAtTimeOfCalibration REAL," +
			"estimateBgAtTimeOfCalibration REAL," +
			"possibleBad BOOLEAN," +
			"checkIn BOOLEAN," +
			"firstDecay REAL," +
			"secondDecay REAL," +
			"firstSlope REAL," +
			"secondSlope REAL," +
			"firstIntercept REAL," +
			"secondIntercept REAL," +
			"firstScale REAL," +
			"secondScale REAL," +
			"FOREIGN KEY (sensorid) REFERENCES sensor(sensorid))";
		
		private static const CREATE_TABLE_SENSOR:String = "CREATE TABLE IF NOT EXISTS sensor (" +
			"sensorid STRING PRIMARY KEY," +
			"lastmodifiedtimestamp TIMESTAMP NOT NULL," +
			"startedat TIMESTAMP," +
			"stoppedat TIMESTAMP," +
			"latestbatterylevel INTEGER)";
		
		private static const CREATE_TABLE_BGREADING:String = "CREATE TABLE IF NOT EXISTS bgreading (" +
			"bgreadingid STRING PRIMARY KEY," +
			"lastmodifiedtimestamp TIMESTAMP NOT NULL," +
			"timestamp TIMESTAMP NOT NULL," +
			"sensorid STRING," +
			"calibrationid STRING," +
			"rawData REAL," +
			"filteredData REAL," +
			"ageAdjustedRawValue REAL," +
			"calibrationFlag BOOLEAN," +
			"calculatedValue REAL," +
			"filteredCalculatedValue REAL," +
			"calculatedValueSlope REAL," +
			"a REAL," +
			"b REAL," +
			"c REAL," +
			"ra REAL," +
			"rb REAL," +
			"rc REAL," +
			"rawCalculated REAL," +
			"hideSlope BOOLEAN," +
			"noise STRING " + ")";
		
		private static const CREATE_TABLE_COMMON_SETTINGS:String = "CREATE TABLE IF NOT EXISTS commonsettings(" +
			"id INTEGER," +
			"value TEXT, " +
			"lastmodifiedtimestamp TIMESTAMP NOT NULL)";
		
		private static const CREATE_TABLE_LOCAL_SETTINGS:String = "CREATE TABLE IF NOT EXISTS localsettings(" +
			"id INTEGER," +
			"value TEXT, " +
			"lastmodifiedtimestamp TIMESTAMP NOT NULL)";
		
		private static const SELECT_ALL_BLUETOOTH_DEVICES:String = "SELECT * from bluetoothdevice";
		private static const INSERT_DEFAULT_BLUETOOTH_DEVICE:String = "INSERT into bluetoothdevice (bluetoothdevice_id, name, address, lastmodifiedtimestamp) VALUES (:bluetoothdevice_id,:name, :address, :lastmodifiedtimestamp)";
		private static const INSERT_LOG:String = "INSERT into logging (logging_id, log, logtimestamp, lastmodifiedtimestamp) VALUES (:logging_id, :log, :logtimestamp, :lastmodifiedtimestamp)";
		private static const DELETE_OLD_LOGS:String = "DELETE FROM logging where (logtimestamp < :logtimestamp)";
		
		/**
		 * to update the bloothdevice, there's only one, no need to have a where clause
		 */
		private static const UPDATE_BLUETOOTH_DEVICE:String = "UPDATE bluetoothdevice SET address = :address, name = :name, lastmodifiedtimestamp = :lastmodifiedtimestamp"; 
		/**
		 * constructor, should not be used
		 */
		
		private static var databaseInformationEvent:DatabaseEvent;
		
		public function Database()
		{
			if (_instance != null) {
				throw new Error("Database class constructor can not be used");	
			}
		}
		
		/**
		 * Create the asynchronous connection to the database<br>
		 * In the complete flow first an attempt will be made to open the database in update mode. <br>
		 * If that fails, it means the database is not existing yet. Then an attempt is made to copy a sample from the assets<br>
		 * <br>
		 * Independent of the result of the attempt to open the database and to copy from the assets, all tables will be created (if not existing yet).<br>
		 * <br>
		 * A default bluetooth device is created if not existing yet with name "", address "", lastmodifiedtimestamp current date, id = BlueToothDevice.DEFAULT_BLUETOOTH_DEVICE_ID
		 **/
		public static function init():void
		{
			if (debugMode) trace("Database.init");
			
			dbFile  = File.applicationStorageDirectory.resolvePath(dbFileName);
			
			aConn = new SQLConnection();
			aConn.addEventListener(SQLEvent.OPEN, onConnOpen);
			aConn.addEventListener(SQLErrorEvent.ERROR, onConnError);
			if (debugMode) trace("Database.as : Attempting to open database in update mode. Database:0001");
			aConn.openAsync(dbFile, SQLMode.UPDATE);
			
			function onConnOpen(se:SQLEvent):void
			{
				if (debugMode) trace("Database.as : SQL Connection successfully opened. Database:0002");
				aConn.removeEventListener(SQLEvent.OPEN, onConnOpen);
				aConn.removeEventListener(SQLErrorEvent.ERROR, onConnError);	
				createTables();
			}
			
			function onConnError(see:SQLErrorEvent):void
			{
				if (debugMode) trace("Database.as : SQL Error while attempting to open database in update mode. New attempt");
				aConn.removeEventListener(SQLEvent.OPEN, onConnOpen);
				aConn.removeEventListener(SQLErrorEvent.ERROR, onConnError);
				reAttempt();
			}
			
			function reAttempt():void {
				//attempt to create dbFile based on a sample in assets directory, 
				//if that fails then dbFile will simply not exist and so will be created later on in openAsync 
				databaseWasCopiedFromSampleFile = createDatabaseFromAssets(dbFile);
				aConn = new SQLConnection();
				aConn.addEventListener(SQLEvent.OPEN, onConnOpen);
				aConn.addEventListener(SQLErrorEvent.ERROR, onConnError);
				if (debugMode) trace("Database.as : Attempting to open database in creation mode. Database:0004");
				aConn.openAsync(dbFile, SQLMode.CREATE);
			}
		}
		
		private static function createTables():void
		{			
			if (debugMode) trace("Database.as : in method createtables");
			sqlStatement = new SQLStatement();
			sqlStatement.sqlConnection = aConn;
			createCalibrationRequestTable();				
		}
		
		private static function createCalibrationRequestTable():void {
			sqlStatement.clearParameters();
			sqlStatement.text = CREATE_TABLE_CALIBRATION_REQUEST;
			sqlStatement.addEventListener(SQLEvent.RESULT,tableCreated);
			sqlStatement.addEventListener(SQLErrorEvent.ERROR,tableCreationError);
			sqlStatement.execute();
			
			function tableCreated(se:SQLEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				createSensorTable();
			}
			
			function tableCreationError(see:SQLErrorEvent):void {
				if (debugMode) trace("Database.as : Failed to create calibration request table. Database:0024");
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				dispatchInformation('failed_to_create_calibration_request_table', see != null ? see.error.message:null);
			}
		}
		
		private static function createSensorTable():void {
			sqlStatement.clearParameters();
			sqlStatement.text = CREATE_TABLE_SENSOR;
			sqlStatement.addEventListener(SQLEvent.RESULT,tableCreated);
			sqlStatement.addEventListener(SQLErrorEvent.ERROR,tableCreationError);
			sqlStatement.execute();
			
			function tableCreated(se:SQLEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				createCalibrationTable();
			}
			
			function tableCreationError(see:SQLErrorEvent):void {
				if (debugMode) trace("Database.as : Failed to create sensor table. Database:0028");
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				dispatchInformation('failed_to_create_sensor_table', see != null ? see.error.message:null);
			}
		}
		
		private static function createCalibrationTable():void {
			sqlStatement.clearParameters();
			sqlStatement.text = CREATE_TABLE_CALIBRATION;
			sqlStatement.addEventListener(SQLEvent.RESULT,tableCreated);
			sqlStatement.addEventListener(SQLErrorEvent.ERROR,tableCreationError);
			sqlStatement.execute();
			
			function tableCreated(se:SQLEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				createBGreadingTable();
			}
			
			function tableCreationError(see:SQLErrorEvent):void {
				if (debugMode) trace("Database.as : Failed to create calibration table. Database:0026");
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				dispatchInformation('failed_to_create_calibration_table', see != null ? see.error.message:null);
			}
		}
		
		private static function createBGreadingTable():void {
			sqlStatement.clearParameters();
			sqlStatement.text = CREATE_TABLE_BGREADING;
			sqlStatement.addEventListener(SQLEvent.RESULT,tableCreated);
			sqlStatement.addEventListener(SQLErrorEvent.ERROR,tableCreationError);
			sqlStatement.execute();
			
			function tableCreated(se:SQLEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				createCommonSettingsTable();
			}
			
			function tableCreationError(see:SQLErrorEvent):void {
				if (debugMode) trace("Database.as : Failed to create bgreading table. Database:0030");
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				dispatchInformation('failed_to_create_bgreading_table', see != null ? see.error.message:null);
			}
		}
		
		private static function createCommonSettingsTable():void {
			sqlStatement.clearParameters();
			sqlStatement.text = CREATE_TABLE_COMMON_SETTINGS;
			sqlStatement.addEventListener(SQLEvent.RESULT,tableCreated);
			sqlStatement.addEventListener(SQLErrorEvent.ERROR,tableCreationError);
			sqlStatement.execute();
			
			function tableCreated(se:SQLEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				createLocalSettingsTable();
			}
			
			function tableCreationError(see:SQLErrorEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				dispatchInformation('failed_to_create_commonsettings_table', see != null ? see.error.message:null);
			}
		}
		
		private static function createLocalSettingsTable():void {
			sqlStatement.clearParameters();
			sqlStatement.text = CREATE_TABLE_LOCAL_SETTINGS;
			sqlStatement.addEventListener(SQLEvent.RESULT,tableCreated);
			sqlStatement.addEventListener(SQLErrorEvent.ERROR,tableCreationError);
			sqlStatement.execute();
			
			function tableCreated(se:SQLEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				getAllSettings();
			}
			
			function tableCreationError(see:SQLErrorEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				dispatchInformation('failed_to_create_localsettings_table', see != null ? see.error.message:null);
			}
		}
		
		private static function getAllSettings():void {
			sqlStatement.clearParameters();
			sqlStatement.text = "SELECT * FROM commonsettings";
			sqlStatement.addEventListener(SQLEvent.RESULT, allCommonSettingsRetrieved);
			sqlStatement.addEventListener(SQLErrorEvent.ERROR, allCommonSettingsRetrievalFailed);
			sqlStatement.execute();
			var result:Array;
			
			function allCommonSettingsRetrieved(se:SQLEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT, allCommonSettingsRetrieved);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR, allCommonSettingsRetrievalFailed);
				result = sqlStatement.getResult().data;
				if (result == null)
					result = new Array(0);
				if (result is Array) { //TODO what if it's not an array ?
					for each (var o:Object in result) {
						CommonSettings.setCommonSetting((o.id as int),(o.value as String) == "-" ? "":(o.value as String), false);
					}
				} 
				addMissingCommonSetting(result.length);
			}
			
			function allCommonSettingsRetrievalFailed(see:SQLErrorEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT, allCommonSettingsRetrieved);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR, allCommonSettingsRetrievalFailed);
				if (debugMode) trace("Failure in get all common settings - Database 0035");
				dispatchInformation('error_while_retrieving_common_settings_in_db', see.error.message + " - " + see.error.details);
			}
			
			function allLocalSettingsRetrievalFailed(see:SQLErrorEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT, allLocalSettingsRetrieved);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR, allLocalSettingsRetrievalFailed);
				if (debugMode) trace("Failure in get all local settings - Database 0036");
				dispatchInformation('error_while_retrieving_local_settings_in_db', see.error.message + " - " + see.error.details);
			}
			
			function addMissingCommonSetting(settingId:int):void {
				if (settingId == CommonSettings.getNumberOfSettings()) {
					sqlStatement.clearParameters();
					sqlStatement.text = "SELECT * FROM localsettings";
					sqlStatement.addEventListener(SQLEvent.RESULT, allLocalSettingsRetrieved);
					sqlStatement.addEventListener(SQLErrorEvent.ERROR, allLocalSettingsRetrievalFailed);
					sqlStatement.execute();
				} else {
					insertCommonSetting(settingId, CommonSettings.getCommonSetting(settingId));
					addMissingCommonSetting(settingId +1);
				}
			}
			
			function allLocalSettingsRetrieved(se:SQLEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT, allLocalSettingsRetrieved);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR, allLocalSettingsRetrievalFailed);
				result = sqlStatement.getResult().data;
				if (result == null)
					result = new Array(0);
				if (result is Array) { //TODO what if it's not an array ?
					for each (var o:Object in result) {
						LocalSettings.setLocalSetting((o.id as int),(o.value as String) == "-" ? "":(o.value as String), false);
					}
				} 
				addMissingLocalSetting(result.length);
			}
			
			function addMissingLocalSetting(settingId:int):void {
				if (settingId == LocalSettings.getNumberOfSettings()) {
					createBlueToothDeviceTable();
				} else {
					insertLocalSetting(settingId, LocalSettings.getLocalSetting(settingId));
					addMissingLocalSetting(settingId +1);
				}
			}
		}
		
		private static function createBlueToothDeviceTable():void {
			sqlStatement.clearParameters();
			sqlStatement.text = CREATE_TABLE_BLUETOOTH_DEVICE;
			sqlStatement.addEventListener(SQLEvent.RESULT,tableCreated);
			sqlStatement.addEventListener(SQLErrorEvent.ERROR,tableCreationError);
			sqlStatement.execute();
			
			function tableCreated(se:SQLEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				selectBlueToothDevices();
			}
			
			function tableCreationError(see:SQLErrorEvent):void {
				if (debugMode) trace("Database.as : Failed to create BlueToothDevice table. Database:0005");
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				dispatchInformation("failed_to_create_bluetoothdevice_table", see.error.message + " - " + see.error.details);
			}
		}
		
		private static function selectBlueToothDevices():void {
			sqlStatement.clearParameters();
			sqlStatement.text = SELECT_ALL_BLUETOOTH_DEVICES;
			sqlStatement.addEventListener(SQLEvent.RESULT,blueToothDevicesSelected);
			sqlStatement.addEventListener(SQLErrorEvent.ERROR,blueToothDevicesSelectionFailed);
			sqlStatement.execute();
			
			function blueToothDevicesSelected(se:SQLEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT,blueToothDevicesSelected);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,blueToothDevicesSelectionFailed);
				var result:Object = sqlStatement.getResult().data;
				if (result != null) {
					if (result is Array) {
						if ((result as Array).length == 1) {
							//there's a bluetoothdevice already, no need to further check
							createLoggingTable();
							return;
						}
					}
				}
				//not using else here because i think there might be other cases like restult not being null but having no elements ?
				insertBlueToothDevice();
			}
			
			function blueToothDevicesSelectionFailed(se:SQLErrorEvent):void {
				if (debugMode) trace("Database.as : Failed to select BlueToothDevices. Database:0009");
				sqlStatement.removeEventListener(SQLEvent.RESULT,blueToothDevicesSelected);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,blueToothDevicesSelectionFailed);
				dispatchInformation("failed_to_select_bluetoothdevice", se.error.message + " - " + se.error.details);
			}
		}
		
		/**
		 * will add one row, with name and address "", and default id<br>
		 * asynchronous
		 */
		private static function insertBlueToothDevice():void {
			sqlStatement.clearParameters();
			sqlStatement.text = INSERT_DEFAULT_BLUETOOTH_DEVICE;
			sqlStatement.parameters[":bluetoothdevice_id"] = BlueToothDevice.DEFAULT_BLUETOOTH_DEVICE_ID;
			sqlStatement.parameters[":name"] = ""; 
			sqlStatement.parameters[":address"] = "";
			sqlStatement.parameters[":lastmodifiedtimestamp"] = (new Date()).valueOf();
			sqlStatement.addEventListener(SQLEvent.RESULT,defaultBlueToothDeviceInserted);
			sqlStatement.addEventListener(SQLErrorEvent.ERROR,defaultBlueToothDeviceInsetionFailed);
			sqlStatement.execute();
			
			function defaultBlueToothDeviceInserted(se:SQLEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT,defaultBlueToothDeviceInserted);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,defaultBlueToothDeviceInsetionFailed);
				createLoggingTable();
			}
			
			function defaultBlueToothDeviceInsetionFailed(see:SQLErrorEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT,defaultBlueToothDeviceInserted);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,defaultBlueToothDeviceInsetionFailed);
				if (debugMode) trace("Database.as : insertBlueToothDevice failed. Database 0014");
				dispatchInformation("failed_to_insert_bluetoothdevice", see.error.message + " - " + see.error.details);
			}
		}
		
		private static function createLoggingTable():void {
			sqlStatement.clearParameters();
			sqlStatement.text = CREATE_TABLE_LOGGING;
			sqlStatement.addEventListener(SQLEvent.RESULT,tableCreated);
			sqlStatement.addEventListener(SQLErrorEvent.ERROR,tableCreationError);
			sqlStatement.execute();
			
			function tableCreated(se:SQLEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				deleteOldLogFiles();
			}
			
			function tableCreationError(see:SQLErrorEvent):void {
				if (debugMode) trace("Database.as : Failed to create Logging table. Database:0017");
				sqlStatement.removeEventListener(SQLEvent.RESULT,tableCreated);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,tableCreationError);
				dispatchInformation("failed_to_create_logging_table", see.error.message + " - " + see.error.details);
			}
		}
		
		/**
		 * asynchronous 
		 */
		private static function deleteOldLogFiles():void {
			sqlStatement.clearParameters();
			sqlStatement.text = DELETE_OLD_LOGS;
			sqlStatement.parameters[":logtimestamp"] = (new Date()).valueOf() - maxDaysToKeepLogfiles * 24 * 60 * 60 * 1000;
			
			sqlStatement.addEventListener(SQLEvent.RESULT,oldLogFilesDeleted);
			sqlStatement.addEventListener(SQLErrorEvent.ERROR,oldLogFileDeletionFailed);
			sqlStatement.execute();
			
			function oldLogFilesDeleted(se:SQLEvent):void {
				sqlStatement.removeEventListener(SQLEvent.RESULT,oldLogFilesDeleted);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,oldLogFileDeletionFailed);
				finishedCreatingTables();
			}
			
			function oldLogFileDeletionFailed(see:SQLErrorEvent):void {
				if (debugMode) trace("Database.as : Failed to delete old logfiles. Database:0021");
				sqlStatement.removeEventListener(SQLEvent.RESULT,oldLogFilesDeleted);
				sqlStatement.removeEventListener(SQLErrorEvent.ERROR,oldLogFileDeletionFailed);
				dispatchInformation("failed_to_delete_old_logfiles", see.error.message + " - " + see.error.details);
			}
		}
		
		private static function finishedCreatingTables():void {
			
			var event:DatabaseEvent = new DatabaseEvent(DatabaseEvent.DATABASE_INIT_FINISHED_EVENT);
			instance.dispatchEvent(event);
		}
		
		private static function createDatabaseFromAssets(targetFile:File):Boolean 			
		{
			var isSuccess:Boolean = true; 
			
			var sampleFile:File = File.applicationDirectory.resolvePath("assets/database/" + sampleDatabaseFileName);
			if ( !sampleFile.exists )
			{
				isSuccess = false;
			}
			else
			{
				sampleFile.copyTo(targetFile);			
			}
			return isSuccess;			
		}
		
		/**
		 * synchronous, no returnvalue, will simply overwrite the bluetoothdevice attributes (which is a single instance)<br>
		 */
		public static function getBlueToothDevice():void {
			var returnValue:BlueToothDevice;
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.READ);
				conn.begin();
				var getRequest:SQLStatement = new SQLStatement();
				getRequest.sqlConnection = conn;
				getRequest.text = SELECT_ALL_BLUETOOTH_DEVICES;
				getRequest.execute();
				var result:SQLResult = getRequest.getResult();
				conn.close();
				var numResults:int = result.data.length;
				if (numResults == 1) {
					BlueToothDevice.name = result.data[0].name;
					BlueToothDevice.address = result.data[0].address;
					BlueToothDevice.setLastModifiedTimestamp(result.data[0].lastmodifiedtimestamp); 
				} else {
					dispatchInformation('error_while_getting_bluetooth_device_in_db', 'resulting amount of bluetoothdevices should be 1 but is ' + numResults);
				}
			} catch (error:SQLError) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_bluetooth_device_in_db', error.message + " - " + error.details);
			} catch (other:Error) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_bluetooth_device_in_db', other.getStackTrace().toString());
			}
		}
		
		/**
		 * to update the one and only bluetoothdevice<br>
		 * synchronous
		 */
		public static function updateBlueToothDeviceSynchronous(address:String, name:String, lastModifiedTimeStamp:Number):void {
			if (address == null) address = "";
			if (name == null) name = "";
			try  {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var updateRequest:SQLStatement = new SQLStatement();
				updateRequest.sqlConnection = conn;
				updateRequest.text = "UPDATE bluetoothdevice SET " +
					"lastmodifiedtimestamp = " + (isNaN(lastModifiedTimeStamp) ? (new Date()).valueOf() : lastModifiedTimeStamp) + "," +
					"address = " + (address == "" ? null:("'" + address + "'")) + ", " + 
					"name = " + (name == "" ? null:("'" + name + "'")); 
				updateRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('error_while_updating_bluetooth_device', error.message + " - " + error.details);
			}
		}
		
		public static function insertLogging(logging_id:String, log:String, logTimeStamp:Number, lastModifiedTimeStamp:Number, dispatcher:EventDispatcher):void {
			var insertRequest:SQLStatement;
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				insertRequest = new SQLStatement();
				insertRequest.sqlConnection = conn;
				insertRequest.text = INSERT_LOG;
				insertRequest.parameters[":logging_id"] = logging_id;
				insertRequest.parameters[":log"] = log;
				insertRequest.parameters[":logtimestamp"] = logTimeStamp;
				insertRequest.parameters[":lastmodifiedtimestamp"] = (isNaN(lastModifiedTimeStamp) ? (new Date()).valueOf() : lastModifiedTimeStamp);
				insertRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('failed_to_insert_logging_in_db', error.message + " - " + error.details + "\ninsertRequest.text = " + insertRequest.text);
			}
		}
		
		/**
		 * will get the loggings and dispatch them one by one (ie one event per logging) in the data field of a LOGRETRIEVED_EVENT<br>
		 * If the last string is sent, an additional event is set with data = "END_OF_RESULT"<br>
		 * <br>
		 * until = loggings with timestamp >= until will not be returned. until is timestamp in ms<br>
		 */
		public static function getLoggings(until:Number):void {
			var localSqlStatement:SQLStatement = new SQLStatement();
			var localdispatcher:EventDispatcher = new EventDispatcher();
			
			localdispatcher.addEventListener(SQLEvent.RESULT,onOpenResult);
			localdispatcher.addEventListener(SQLErrorEvent.ERROR,onOpenError);
			
			if (openSQLConnection(localdispatcher))
				onOpenResult(null);
			
			function onOpenResult(se:SQLEvent):void {
				localdispatcher.removeEventListener(SQLEvent.RESULT,onOpenResult);
				localdispatcher.removeEventListener(SQLErrorEvent.ERROR,onOpenError);
				localSqlStatement.addEventListener(SQLEvent.RESULT,loggingsRetrieved);
				localSqlStatement.addEventListener(SQLErrorEvent.ERROR,loggingRetrievalFailed);
				localSqlStatement.sqlConnection = aConn;
				localSqlStatement.text = "SELECT * from logging where logtimestamp < " + until;
				localSqlStatement.execute();
			}
			
			function loggingsRetrieved(se:SQLEvent):void {
				localSqlStatement.removeEventListener(SQLEvent.RESULT,loggingsRetrieved);
				localSqlStatement.removeEventListener(SQLErrorEvent.ERROR,loggingRetrievalFailed);
				var tempObject:Object = localSqlStatement.getResult().data;
				if (tempObject != null) {
					if (tempObject is Array) {
						for each ( var o:Object in tempObject) {
							var event:DatabaseEvent = new DatabaseEvent(DatabaseEvent.LOGRETRIEVED_EVENT);
							event.data = o.log;
							instance.dispatchEvent(event);
						}
					}
				} else {
					//no need to dispatch anything, there are no loggings
				}
				
				var event:DatabaseEvent = new DatabaseEvent(DatabaseEvent.LOGRETRIEVED_EVENT);
				event.data = END_OF_RESULT;
				instance.dispatchEvent(event);
			}
			
			function loggingRetrievalFailed(see:SQLErrorEvent):void {
				localSqlStatement.removeEventListener(SQLEvent.RESULT,loggingsRetrieved);
				localSqlStatement.removeEventListener(SQLErrorEvent.ERROR,loggingRetrievalFailed);
				if (debugMode) trace("Database.as : Failed to retrieve loggings. Database 0022");
				var errorEvent:DatabaseEvent = new DatabaseEvent(DatabaseEvent.ERROR_EVENT);
				errorEvent.data = "Failed to retrieve loggings . Database:0022";
				instance.dispatchEvent(errorEvent);
				
			}
			
			function onOpenError(see:SQLErrorEvent):void {
				localdispatcher.removeEventListener(SQLEvent.RESULT,onOpenResult);
				localdispatcher.removeEventListener(SQLErrorEvent.ERROR,onOpenError);
				if (debugMode) trace("Database.as : Failed to open the database. Database 0023");
				dispatchInformation("failed_to_retrieve_logging_failed_to_open_the_database", see.error.message + " - " + see.error.details);
				var errorEvent:DatabaseEvent = new DatabaseEvent(DatabaseEvent.ERROR_EVENT);
				errorEvent.data = "Database.as : Failed to open the database. Database 0023";
				instance.dispatchEvent(errorEvent);
				
			}
		}
		
		/**
		 * inserts a calibrationrequest in the database<br>
		 * dispatches info if anything goes wrong<br>
		 * synchronous
		 */
		public static function insertCalibrationRequestSychronous(calibrationRequest:CalibrationRequest):void {
			myTrace("creating calibrationrequest in db with requestifabove = " + calibrationRequest.requestIfAbove + ", requestifbelow = " + calibrationRequest.requestIfBelow);
			var insertRequest:SQLStatement;
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				insertRequest = new SQLStatement();
				insertRequest.sqlConnection = conn;
				insertRequest.text = "INSERT INTO calibrationrequest (calibrationrequestid, lastmodifiedtimestamp, requestifabove, requestifbelow, deleted) " +
					"VALUES ('" + calibrationRequest.uniqueId + "', " +
					calibrationRequest.lastModifiedTimestamp + 
					", " +
					calibrationRequest.requestIfAbove + ", " + calibrationRequest.requestIfBelow + ", " +
					"0" + ")";
				insertRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}			
				dispatchInformation('error_while_inserting_calibration_request_in_db', error.message + " - " + error.details);
			}
		}
		
		/**
		 * deletes a calibrationrequest in the database<br>
		 * dispatches info if anything goes wrong 
		 */
		public static function deleteCalibrationRequestSynchronous(calibrationRequest:CalibrationRequest):void {
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var deleteRequest:SQLStatement = new SQLStatement();
				deleteRequest.sqlConnection = conn;
				deleteRequest.text = "UPDATE calibrationrequest SET deleted = 1 where calibrationrequestid = " + "'" + calibrationRequest.uniqueId + "'";
				deleteRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}			
				dispatchInformation('error_while_deleting_calibration_request_in_db', error.message + " - " + error.details);
			}
		}
		
		/**
		 * updates a calibrationrequest in the database<br>
		 * dispatches info if anything goes wrong 
		 */
		public static function updateCalibrationRequestSynchronous(calibrationRequest:CalibrationRequest):void {
			var insertRequest:SQLStatement;
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				insertRequest = new SQLStatement();
				insertRequest.sqlConnection = conn;
				insertRequest.text = "UPDATE calibrationrequest SET " +
					"lastmodifiedtimestamp = " + calibrationRequest.lastModifiedTimestamp.toString() + "," +
					"requestifabove = " + calibrationRequest.requestIfAbove + ", " + 
					"requestifbelow = " + calibrationRequest.requestIfBelow + 
					" WHERE calibrationrequestid = " + "'" + calibrationRequest.uniqueId + "'"; 
				insertRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}			
				dispatchInformation('error_while_updating_calibration_request_in_db', error.message + " - " + error.details + "\ninsertRequest.txt = " + insertRequest.text);
			}
		}
		
		
		/**
		 * deletes all calibrations<br>
		 * REMOVE THIS - CALIBRATIONS SHOULD BE DELETED AFTER X DAYS <br>
		 * synchronous
		 */
		public static function deleteAllCalibrationsSynchronous():void {
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var deleteRequest:SQLStatement = new SQLStatement();
				deleteRequest.sqlConnection = conn;
				deleteRequest.text = "DELETE from calibration";
				deleteRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}			
				dispatchInformation('error_while_deleting_all_calibration_in_db', error.message + " - " + error.details);
			}
		}
		
		/**
		 * deletes all calibrationrequests<br>
		 * synchronous
		 */
		public static function deleteAllCalibrationRequestsSynchronous():void {
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var deleteRequest:SQLStatement = new SQLStatement();
				deleteRequest.sqlConnection = conn;
				deleteRequest.text = "UPDATE calibrationrequest SET deleted = 1";
				deleteRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}			
				dispatchInformation('error_while_deleting_all_calibrationrequests_in_db', error.message + " - " + error.details);
			}
		}
		
		/**
		 * get calibrationRequests with requestIfAbove < value and requestIfBelow > value<br>
		 * return value is not sorted<br>
		 * synchronous<br>
		 * 
		 */
		public static function getCalibrationRequestsForValue(value:Number):ArrayCollection {
			var returnValue:ArrayCollection = new ArrayCollection();
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.READ);
				conn.begin();
				var getRequest:SQLStatement = new SQLStatement();
				getRequest.sqlConnection = conn;
				getRequest.text = "SELECT * FROM calibrationrequest WHERE deleted = 0 AND  requestifabove < " + value + " AND requestifbelow > " + value;
				getRequest.execute();
				var result:SQLResult = getRequest.getResult();
				conn.close();
				if (result.data != null) {
					var numResults:int = result.data.length;
					for (var i:int = 0; i < numResults; i++) 
					{ 
						var row:Object = result.data[i]; 
						returnValue.addItem(new CalibrationRequest(row.requestifabove, row.requestifbelow, row.calibrationrequestid, row.lastmodifiedtimestamp));
					} 
				}
			} catch (error:SQLError) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_calibration_requests_in_db', error.message + " - " + error.details);
			} catch (other:Error) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_calibration_requests_in_db',other.getStackTrace().toString());
			} finally {
				if (conn.connected) conn.close();
				return returnValue;
			}
		}
		
		/**
		 * latest calibrations with the specified sensor id from large to small (ie descending) 
		 */
		public static function getLatestCalibrations(number:int, sensorId:String):ArrayCollection {
			var returnValue:ArrayCollection = new ArrayCollection();
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.READ);
				conn.begin();
				var getRequest:SQLStatement = new SQLStatement();
				getRequest.sqlConnection = conn;
				getRequest.text = "SELECT * FROM calibration WHERE sensorid = '" + sensorId +"'";
				getRequest.execute();
				var result:SQLResult = getRequest.getResult();
				conn.close();
				if (result.data != null) {
					var numResults:int = result.data.length;
					var tempReturnValue:ArrayCollection = new ArrayCollection();
					for (var i:int = 0; i < numResults; i++) 
					{ 
						tempReturnValue.addItem(
							new Calibration(
								result.data[i].timestamp,
								result.data[i].sensorAgeAtTimeOfEstimation,
								((result.data[i].sensorid) as String) == "-" ? null:getSensor(result.data[i].sensorid),
								result.data[i].bg,
								result.data[i].rawValue,
								result.data[i].adjustedRawValue,
								result.data[i].sensorConfidence,
								result.data[i].slopeConfidence,
								result.data[i].rawTimestamp,
								result.data[i].slope,
								result.data[i].intercept,
								result.data[i].distanceFromEstimate,
								result.data[i].estimateRawAtTimeOfCalibration,
								result.data[i].estimateBgAtTimeOfCalibration,
								result.data[i].possibleBad == "1" ? true:false,
								result.data[i].checkIn == "1" ? true:false,
								result.data[i].firstDecay,
								result.data[i].secondDecay,
								result.data[i].firstSlope,
								result.data[i].secondSlope,
								result.data[i].firstIntercept,
								result.data[i].secondIntercept,
								result.data[i].firstScale,
								result.data[i].secondScale,
								result.data[i].lastmodifiedtimestamp,
								result.data[i].calibrationid)
						);
					}
					var dataSortFieldForReturnValue:SortField = new SortField();
					dataSortFieldForReturnValue.name = "timestamp";
					dataSortFieldForReturnValue.numeric = true;
					dataSortFieldForReturnValue.descending = true;//ie from large to small
					var dataSortForBGReadings:Sort = new Sort();
					dataSortForBGReadings.fields=[dataSortFieldForReturnValue];
					tempReturnValue.sort = dataSortForBGReadings;
					tempReturnValue.refresh();
					for (var cntr:int = 0; cntr < tempReturnValue.length; cntr++) {
						returnValue.addItem(tempReturnValue.getItemAt(cntr));
						if (cntr == number - 1) {
							break;
						}
					}
				}
			} catch (error:SQLError) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_latest_calibrations_in_db', error.message + " - " + error.details);
			} catch (other:Error) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_latest_calibrations_in_db',other.getStackTrace().toString());
			} finally {
				if (conn.connected) conn.close();
				return returnValue;
			}
		}
		
		
		/**
		 * get calibrations with sensorid and last x days and slopeconfidence != 0 and sensorConfidence != 0<br>
		 * order by timestamp descending<br>
		 * synchronous<br>
		 */
		public static function getCalibrationForSensorInLastXDays(days:int, sensorid:String):ArrayCollection {
			var returnValue:ArrayCollection = new ArrayCollection();
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.READ);
				conn.begin();
				var getRequest:SQLStatement = new SQLStatement();
				getRequest.sqlConnection = conn;
				getRequest.text = "SELECT * FROM calibration WHERE sensorid = '" + sensorid + "' AND slopeConfidence != 0 " +
					"AND sensorConfidence != 0 and timestamp > " + (new Date((new Date()).valueOf() - (60000 * 60 * 24 * days))).valueOf();
				getRequest.execute();
				var result:SQLResult = getRequest.getResult();
				conn.close();
				if (result.data != null) {
					var numResults:int = result.data.length;
					for (var i:int = 0; i < numResults; i++) 
					{ 
						returnValue.addItem(
							new Calibration(
								result.data[i].timestamp,
								result.data[i].sensorAgeAtTimeOfEstimation,
								((result.data[i].sensorid) as String) == "-" ? null:getSensor(result.data[i].sensorid),
								result.data[i].bg,
								result.data[i].rawValue,
								result.data[i].adjustedRawValue,
								result.data[i].sensorConfidence,
								result.data[i].slopeConfidence,
								result.data[i].rawTimestamp,
								result.data[i].slope,
								result.data[i].intercept,
								result.data[i].distanceFromEstimate,
								result.data[i].estimateRawAtTimeOfCalibration,
								result.data[i].estimateBgAtTimeOfCalibration,
								result.data[i].possibleBad == "1" ? true:false,
								result.data[i].checkIn == "1" ? true:false,
								result.data[i].firstDecay,
								result.data[i].secondDecay,
								result.data[i].firstSlope,
								result.data[i].secondSlope,
								result.data[i].firstIntercept,
								result.data[i].secondIntercept,
								result.data[i].firstScale,
								result.data[i].secondScale,
								result.data[i].lastmodifiedtimestamp,
								result.data[i].calibrationid)
						);
					}
					var dataSortFieldForReturnValue:SortField = new SortField();
					dataSortFieldForReturnValue.name = "timestamp";
					dataSortFieldForReturnValue.numeric = true;
					dataSortFieldForReturnValue.descending = true;//ie from large to small
					var dataSortForBGReadings:Sort = new Sort();
					dataSortForBGReadings.fields=[dataSortFieldForReturnValue];
					returnValue.sort = dataSortForBGReadings;
					returnValue.refresh();
				}
			} catch (error:SQLError) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_for_sensor_in_lastxdays_in_db', error.message + " - " + error.details);
			} catch (other:Error) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_for_sensor_in_lastxdays_in_db',other.getStackTrace().toString());
			} finally {
				if (conn.connected) conn.close();
				return returnValue;
			}
		}
		
		/**
		 * get first or last calibration for specified sensorid<br>
		 * if first = true then it will return the first, otherwise the last<br>
		 * returns null if there's none
		 * synchronous<br>
		 */
		public static function getLastOrFirstCalibration(sensorid:String, first:Boolean):Calibration {
			var returnValue:Calibration = null;
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.READ);
				conn.begin();
				var getRequest:SQLStatement = new SQLStatement();
				getRequest.sqlConnection = conn;
				getRequest.text = "SELECT * FROM calibration WHERE sensorid = '" + sensorid + "'";
				getRequest.execute();
				conn.close();
				var result:SQLResult = getRequest.getResult();
				if (result.data != null) {
					if (result.data != null) {
						var calibrations:ArrayCollection = new ArrayCollection();
						var numResults:int = result.data.length;
						for (var i:int = 0; i < numResults; i++) 
						{ 
							calibrations.addItem(
								new Calibration(
									result.data[i].timestamp,
									result.data[i].sensorAgeAtTimeOfEstimation,
									((result.data[i].sensorid) as String) == "-" ? null:getSensor(result.data[i].sensorid),
									result.data[i].bg,
									result.data[i].rawValue,
									result.data[i].adjustedRawValue,
									result.data[i].sensorConfidence,
									result.data[i].slopeConfidence,
									result.data[i].rawTimestamp,
									result.data[i].slope,
									result.data[i].intercept,
									result.data[i].distanceFromEstimate,
									result.data[i].estimateRawAtTimeOfCalibration,
									result.data[i].estimateBgAtTimeOfCalibration,
									result.data[i].possibleBad == "1" ? true:false,
									result.data[i].checkIn == "1" ? true:false,
									result.data[i].firstDecay,
									result.data[i].secondDecay,
									result.data[i].firstSlope,
									result.data[i].secondSlope,
									result.data[i].firstIntercept,
									result.data[i].secondIntercept,
									result.data[i].firstScale,
									result.data[i].secondScale,
									result.data[i].lastmodifiedtimestamp,
									result.data[i].calibrationid)
							);
						} 
						var dataSortFieldForReturnValue:SortField = new SortField();
						dataSortFieldForReturnValue.name = "timestamp";
						dataSortFieldForReturnValue.numeric = true;
						if (!first)
							dataSortFieldForReturnValue.descending = true;//ie large to small
						var dataSortForBGReadings:Sort = new Sort();
						dataSortForBGReadings.fields=[dataSortFieldForReturnValue];
						calibrations.sort = dataSortForBGReadings;
						calibrations.refresh();
						if (calibrations.length > 0)
							returnValue = calibrations.getItemAt(0) as Calibration;
					}
				}
			} catch (error:SQLError) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_last_or_first_calibration_in_db', error.message + " - " + error.details);
			} catch (other:Error) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_last_or_first_calibration_in_db',other.getStackTrace().toString());
			} finally {
				if (conn.connected) conn.close();
				return returnValue;
			}
		}
		
		/**
		 * inserts a calibration in the database<br>
		 * dispatches info if anything goes wrong 
		 */
		public static function insertCalibrationSynchronous(calibration:Calibration):void {
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var insertRequest:SQLStatement = new SQLStatement();
				insertRequest.sqlConnection = conn;
				insertRequest.text = "INSERT INTO calibration (" +
					"calibrationid, " +
					"lastmodifiedtimestamp, " +
					"timestamp," +
					"sensorAgeAtTimeOfEstimation," +
					"sensorid," +
					"bg," +
					"rawValue," +
					"adjustedRawValue," +
					"sensorConfidence," +
					"slopeConfidence," +
					"rawTimestamp," +
					"slope," +
					"intercept," +
					"distanceFromEstimate," +
					"estimateRawAtTimeOfCalibration," +
					"estimateBgAtTimeOfCalibration," +
					"possibleBad," +
					"checkIn," +
					"firstDecay," +
					"secondDecay," +
					"firstSlope," +
					"secondSlope," +
					"firstIntercept," +
					"secondIntercept," +
					"firstScale," +
					"secondScale)" +
					"VALUES ('" + calibration.uniqueId + "', " +
					calibration.lastModifiedTimestamp + ", " +
					calibration.timestamp + ", " +
					calibration.sensorAgeAtTimeOfEstimation + ", " +
					"'" + (calibration.sensor == null ? "-" : calibration.sensor.uniqueId) + "', " + 
					calibration.bg +", " + 
					calibration.rawValue +", " + 
					calibration.adjustedRawValue +", " + 
					calibration.sensorConfidence  +", " + 
					calibration.slopeConfidence +", " +
					calibration.rawTimestamp +", " +
					calibration.slope +", " +
					calibration.intercept +", " +
					calibration.distanceFromEstimate +", " +
					calibration.estimateRawAtTimeOfCalibration +", " +
					calibration.estimateBgAtTimeOfCalibration +", " +
					(calibration.possibleBad ? "1":"0") +", " +
					(calibration.checkIn ? "1":"0") +", " +
					calibration.firstDecay +", " +
					calibration.secondDecay +", " +
					calibration.firstSlope +", " +
					calibration.secondSlope +", " +
					calibration.firstIntercept +", " +
					calibration.secondIntercept +", " +
					calibration.firstScale +", " +
					calibration.secondScale + ")";
				insertRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('error_while_inserting_calibration_in_db', error.message + " - " + error.details);
			}
		}
		
		/**
		 * deletes a calibration in the database<br>
		 * dispatches info if anything goes wrong <br>
		 */
		public static function deleteCalibrationSynchronous(calibration:Calibration):void {
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var deleteRequest:SQLStatement = new SQLStatement();
				deleteRequest.sqlConnection = conn;
				deleteRequest.text = "DELETE from calibration where calibrationid = " + "'" + calibration.uniqueId + "'";
				deleteRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('error_while_deleting_calibration_in_db', error.message + " - " + error.details);
			}
		}
		
		/**
		 * updates a calibration in the database<br>
		 * dispatches info if anything goes wrong 
		 */
		public static function updateCalibrationSynchronous(calibration:Calibration):void {
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var updateRequest:SQLStatement = new SQLStatement();
				updateRequest.sqlConnection = conn;
				updateRequest.text = "UPDATE calibration SET " +
					"lastmodifiedtimestamp = " + calibration.lastModifiedTimestamp + ", " + 
					"timestamp = " + calibration.timestamp + ", " + 
					"sensorAgeAtTimeOfEstimation = " + calibration.sensorAgeAtTimeOfEstimation + ", " + 
					"sensorid = '" + (calibration.sensor == null ? "-" : calibration.sensor.uniqueId) + "', " +
					"bg = " +  calibration.bg + ", " +
					"rawValue = " +  calibration.rawValue + ", " +
					"adjustedRawValue = " +  calibration.adjustedRawValue + ", " +
					"sensorConfidence = " +  calibration.sensorConfidence + ", " +
					"slopeConfidence = " +  calibration.slopeConfidence + ", " +
					"rawTimestamp = " +  calibration.rawTimestamp + ", " +
					"slope = " +  calibration.slope + ", " +
					"intercept = " +  calibration.intercept + ", " +
					"distanceFromEstimate = " +  calibration.distanceFromEstimate + ", " +
					"estimateRawAtTimeOfCalibration = " +  calibration.estimateRawAtTimeOfCalibration + ", " +
					"estimateBgAtTimeOfCalibration = " +  calibration.estimateBgAtTimeOfCalibration + ", " +
					"possibleBad = " +  (calibration.possibleBad? "1":"0") + ", " +
					"checkIn = " + (calibration.checkIn? "1":"0") + ", " +
					"firstDecay = " +  calibration.firstDecay + ", " +
					"secondDecay = " +  calibration.secondDecay + ", " +
					"firstSlope = " +  calibration.firstSlope + ", " +
					"secondSlope = " +  calibration.secondSlope + ", " +
					"firstIntercept = " + calibration. firstIntercept + ", " +
					"secondIntercept = " +  calibration.secondIntercept + ", " +
					"firstScale = " +  calibration.firstScale + ", " +
					"secondScale = " +  calibration.secondScale + " " +
					"WHERE calibrationid = " + "'" + calibration.uniqueId + "'";
				updateRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('error_while_updating_calibration_in_db', error.message + " - " + error.details);
			}
		}
		
		/**
		 * get calibration for specified uniqueId<br>
		 * synchronous
		 */
		public static function getCalibration(uniqueId:String):Calibration {
			var returnValue:Calibration = null;
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.READ);
				conn.begin();
				var getRequest:SQLStatement = new SQLStatement();
				getRequest.sqlConnection = conn;
				getRequest.text = "SELECT * FROM calibration WHERE calibrationid = '" + uniqueId + "'";
				getRequest.execute();
				var result:SQLResult = getRequest.getResult();
				conn.close();
				if (result.data != null) {
					var numResults:int = result.data.length;
					if (numResults == 1) {
						returnValue = new Calibration(
							result.data[0].timestamp,
							result.data[0].sensorAgeAtTimeOfEstimation,
							((result.data[0].sensorid) as String) == "-" ? null:getSensor(result.data[0].sensorid),
							result.data[0].bg,
							result.data[0].rawValue,
							result.data[0].adjustedRawValue,
							result.data[0].sensorConfidence,
							result.data[0].slopeConfidence,
							result.data[0].rawTimestamp,
							result.data[0].slope,
							result.data[0].intercept,
							result.data[0].distanceFromEstimate,
							result.data[0].estimateRawAtTimeOfCalibration,
							result.data[0].estimateBgAtTimeOfCalibration,
							result.data[0].possibleBad == "1" ? true:false,
							result.data[0].checkIn == "1" ? true:false,
							result.data[0].firstDecay,
							result.data[0].secondDecay,
							result.data[0].firstSlope,
							result.data[0].secondSlope,
							result.data[0].firstIntercept,
							result.data[0].secondIntercept,
							result.data[0].firstScale,
							result.data[0].secondScale,
							result.data[0].lastmodifiedtimestamp,
							result.data[0].calibrationid
						)
					} else {
						dispatchInformation('error_while_getting_calibration_in_db','resulting amount of calibrations should be 1 but is ' + numResults);
					}
				}
			} catch (error:SQLError) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_calibration_in_db', error.message + " - " + error.details);
			} catch (other:Error) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_calibration_in_db', other.getStackTrace().toString());
			} finally {
				if (conn.connected) conn.close();
				return returnValue;
			}
		}
		
		/**
		 * get calibration for specified sensorId<br>
		 * if there's no calibration for the specified sensorId then the returnvalue is an empty arraycollection<br>
		 * the calibrations will be order in descending order by timestamp<br>
		 * synchronous
		 */
		public static function getCalibrationForSensorId(sensorId:String):ArrayCollection {
			var returnValue:ArrayCollection = new ArrayCollection();
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.READ);
				conn.begin();
				var getRequest:SQLStatement = new SQLStatement();
				getRequest.sqlConnection = conn;
				getRequest.text = "SELECT * FROM calibration WHERE sensorid = '" + sensorId + "'";
				getRequest.execute();
				var result:SQLResult = getRequest.getResult();
				conn.close();
				if (result.data != null) {
					var numResults:int = result.data.length;
					for (var i:int = 0; i < numResults; i++) 
					{ 
						returnValue.addItem(new Calibration(
							result.data[i].timestamp,
							result.data[i].sensorAgeAtTimeOfEstimation,
							((result.data[i].sensorid) as String) == "-" ? null:getSensor(result.data[i].sensorid),
							result.data[i].bg,
							result.data[i].rawValue,
							result.data[i].adjustedRawValue,
							result.data[i].sensorConfidence,
							result.data[i].slopeConfidence,
							result.data[i].rawTimestamp,
							result.data[i].slope,
							result.data[i].intercept,
							result.data[i].distanceFromEstimate,
							result.data[i].estimateRawAtTimeOfCalibration,
							result.data[i].estimateBgAtTimeOfCalibration,
							result.data[i].possibleBad == "1" ? true:false,
							result.data[i].checkIn == "1" ? true:false,
							result.data[i].firstDecay,
							result.data[i].secondDecay,
							result.data[i].firstSlope,
							result.data[i].secondSlope,
							result.data[i].firstIntercept,
							result.data[i].secondIntercept,
							result.data[i].firstScale,
							result.data[i].secondScale,
							result.data[i].lastmodifiedtimestamp,
							result.data[i].calibrationid
						));
					} 
					var dataSortFieldForReturnValue:SortField = new SortField();
					dataSortFieldForReturnValue.name = "timestamp";
					dataSortFieldForReturnValue.numeric = true;
					dataSortFieldForReturnValue.descending = true;//ie large to small
					var dataSortForBGReadings:Sort = new Sort();
					dataSortForBGReadings.fields=[dataSortFieldForReturnValue];
					returnValue.sort = dataSortForBGReadings;
					returnValue.refresh();

				}
			} catch (error:SQLError) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_calibration_in_db', error.message + " - " + error.details);
			} catch (other:Error) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_calibration_in_db', other.getStackTrace().toString());
			} finally {
				if (conn.connected) conn.close();
				return returnValue;
			}
		}
		
		
		/**
		 * inserts a sensor in the database<br>
		 * dispatches info if anything goes wrong 
		 */
		public static function insertSensor(sensor:Sensor):void {
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var insertRequest:SQLStatement = new SQLStatement();
				insertRequest.sqlConnection = conn;
				insertRequest.text = "INSERT INTO sensor (" +
					"sensorid, " +
					"lastmodifiedtimestamp, " +
					"startedat," +
					"stoppedat," +
					"latestbatterylevel" +
					")" +
					"VALUES ('" + sensor.uniqueId + "', " +
					sensor.lastModifiedTimestamp + ", " +
					sensor.startedAt + ", " +
					sensor.stoppedAt + ", " +
					sensor.latestBatteryLevel + 
					")";
				insertRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('error_while_inserting_sensor_in_db', error.message + " - " + error.details);
			}
		}
		
		/**
		 * deletes a sensor in the database<br>
		 * dispatches info if anything goes wrong 
		 */
		public static function deleteSensor(sensor:Sensor):void {
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var deleteRequest:SQLStatement = new SQLStatement();
				deleteRequest.sqlConnection = conn;
				deleteRequest.text = "DELETE from sensor where sensorid = " + "'" + sensor.uniqueId + "'";
				deleteRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('error_while_deleting_sensor_in_db', error.message + " - " + error.details);
			}
		}
		
		/**
		 * updates a sensor in the database<br>
		 * dispatches info if anything goes wrong 
		 */
		public static function updateSensor(sensor:Sensor):void {
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var updateRequest:SQLStatement = new SQLStatement();
				updateRequest.sqlConnection = conn;
				var text:String = "UPDATE sensor SET ";
					text += "lastmodifiedtimestamp = " + sensor.lastModifiedTimestamp + ", "; 
						text += 					"startedat = " + sensor.startedAt + ", "; 
						text += "stoppedat = " + sensor.stoppedAt + ", ";
						text += "latestbatterylevel = " + sensor.latestBatteryLevel + " ";
						text += "WHERE sensorid = " + "'" + sensor.uniqueId + "'";
						updateRequest.text = text;
				updateRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('error_while_updating_sensor_in_db', error.message + " - " + error.details);
			}
		}
		
		/**
		 * get sensor for specified uniqueId<br>
		 * null if none found<br>
		 * synchronous
		 */
		public static function getSensor(uniqueId:String):Sensor {
			var returnValue:Sensor = null;
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.READ);
				conn.begin();
				var getRequest:SQLStatement = new SQLStatement();
				getRequest.sqlConnection = conn;
				getRequest.text = "SELECT * FROM sensor WHERE sensorid = '" + uniqueId + "'";
				while (aConn.inTransaction){};
				getRequest.execute();
				var result:SQLResult = getRequest.getResult();
				conn.close();
				if (result.data != null) {
					var numResults:int = result.data.length;
					if (numResults == 1) {
						returnValue = new Sensor(
							result.data[0].startedat,
							result.data[0].stoppedat,
							result.data[0].latestbatterylevel,
							result.data[0].sensorid,
							result.data[0].lastmodifiedtimestamp
						)
					} else {
						dispatchInformation('error_while_getting_sensor_in_db','resulting amount of sensors should be 1 but is ' + numResults);
					}
				}
			} catch (error:SQLError) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_sensor_in_db', error.message + " - " + error.details);
			} catch (other:Error) {
				if (conn.connected) conn.close();
				dispatchInformation('error_while_getting_sensor_in_db', other.getStackTrace().toString());
			} finally {
				if (conn.connected) conn.close();
				return returnValue;
			}
		}
		
		/**
		 * inserts a bgreading in the database<br>
		 * synchronous<br>
		 * dispatches info if anything goes wrong 
		 */
		public static function insertBgReadingSynchronous(bgreading:BgReading):void {
			try {
				var calibration:Calibration = bgreading.calibration;
				var calibrationIdAsString:String = calibration == null ? "-":bgreading.calibration.uniqueId;
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var insertRequest:SQLStatement = new SQLStatement();
				insertRequest.sqlConnection = conn;
				var text:String = "INSERT INTO bgreading (";
				text += "bgreadingid, ";
				text += "lastmodifiedtimestamp, ";
				text += "timestamp,";
				text += "sensorid,";
				text += "calibrationid,";
				text += "rawData,";
				text += "filteredData,";
				text += "ageAdjustedRawValue,";
				text += "calibrationFlag,";
				text += "calculatedValue,";
				text += "filteredCalculatedValue,";
				text += "calculatedValueSlope,";
				text += "a,";
				text += "b,";
				text += "c,";
				text += "ra,";
				text += "rb,";
				text += "rc,";
				text += "rawCalculated,";
				text += "hideSlope,";
				text += "noise) ";
				text += "VALUES ('" + bgreading.uniqueId + "', ";
				text += bgreading.lastModifiedTimestamp + ", ";
				text += bgreading.timestamp + ", ";
				text += "'" + bgreading.sensor.uniqueId +"',"; 
				text += "'" + calibrationIdAsString + "', ";
				text += bgreading.rawData + ", "; 
				text += bgreading.filteredData + ", "; 
				text += bgreading.ageAdjustedRawValue + ", "; 
				text += (bgreading.calibrationFlag ? "1":"0") + ", ";
				text += bgreading.calculatedValue + ", ";
				text += bgreading.filteredCalculatedValue + ", ";
				text += bgreading.calculatedValueSlope + ", ";
				text += bgreading.a + ", ";
				text += bgreading.b + ", ";
				text += bgreading.c + ", ";
				text += bgreading.ra + ", ";
				text += bgreading.rb + ", ";
				text += bgreading.rc + ", ";
				text += bgreading.rawCalculated + ", ";
				text += (bgreading.hideSlope ? "1":"0") + ", ";
				text += "'" + (bgreading.noise == null ? "-":bgreading.noise) + "'" + ")";
				insertRequest.text = text;
				insertRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('error_while_inserting_bgreading_in_db', error.message + " - " + error.details);
			}
		}
		
		/**
		 * deletes a bgreading in the database<br>
		 * dispatches info if anything goes wrong 
		 */
		public static function deleteBgReadingSynchronous(bgreading:BgReading):void {
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var deleteRequest:SQLStatement = new SQLStatement();
				deleteRequest.sqlConnection = conn;
				deleteRequest.text = "DELETE from bgreading where bgreadingid = " + "'" + bgreading.uniqueId + "'";
				deleteRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('error_while_deleting_bgreading_in_db', error.message + " - " + error.details);
			}
		}
		
		/**
		 * updates a calibration in the database<br>
		 * dispatches info if anything goes wrong<br>
		 * synchronous
		 */
		public static function updateBgReadingSynchronous(bgreading:BgReading):void {
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var updateRequest:SQLStatement = new SQLStatement();
				updateRequest.sqlConnection = conn;
				var text:String = "UPDATE bgreading SET ";
				text += "lastmodifiedtimestamp = " + bgreading.lastModifiedTimestamp + ",  "; 
				text += "timestamp = " + bgreading.timestamp + ",  "; 
				text += "sensorid = '" +  bgreading.sensor.uniqueId + "', ";
				text += "calibrationid = " +  (bgreading.calibration == null ? "'-'":("'" + bgreading.calibration.uniqueId + "'")) + ",  ";
				text += "rawData = " +  bgreading.rawData + ",  ";
				text += "filteredData = " +  bgreading.filteredData + ",  ";
				text += "ageAdjustedRawValue = " +  bgreading.ageAdjustedRawValue + ",  ";
				text += "calibrationFlag = " +  (bgreading.calibrationFlag ? "1":"0") + ",  ";
				text += "calculatedValue = " +  bgreading.calculatedValue + ",  ";
				text += "filteredCalculatedValue = " +  bgreading.filteredCalculatedValue + ",  ";
				text += "calculatedValueSlope = " +  bgreading.calculatedValueSlope + ",  ";
				text += "a = " +  bgreading.a + ",  ";
				text += "b = " +  bgreading.b + ",  ";
				text += "c = " +  bgreading.c + ",  ";
				text += "ra = " +  bgreading.ra + ",  ";
				text += "rb = " + bgreading.rb + ",  ";
				text += "rc = " +  bgreading.rc + ",  ";
				text += "rawCalculated = " +  bgreading.rawCalculated + ",  ";
				text += "hideSlope = " +  (bgreading.hideSlope ? "1":"0") + ",  ";
				text += "noise = " +  "'" + (bgreading.noise == null ? "-":bgreading.noise) + "' "; 
				text += "WHERE bgreadingid = " + "'" + bgreading.uniqueId + "' " ;
				updateRequest.text = text;
				updateRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('error_while_updating_bgreading_in_db', error.message + " - " + error.details);
			}
		}
		
		/**
		 * will get the bgreadings and dispatch them one by one (ie one event per bgreading) in the data field of a BGREADING_RETRIEVAL_EVENT<br>
		 * If the last string is sent, an additional event is set with data = "END_OF_RESULT"<br>
		 * <br>
		 * until = loggings with timestamp >= until will not be returned. until is timestamp in ms<br>
		 * asynchronous
		 */
		public static function getBgReadings(until:Number):void {
			var localSqlStatement:SQLStatement = new SQLStatement();
			var localdispatcher:EventDispatcher = new EventDispatcher();
			
			localdispatcher.addEventListener(SQLEvent.RESULT,onOpenResult);
			localdispatcher.addEventListener(SQLErrorEvent.ERROR,onOpenError);
			
			if (openSQLConnection(localdispatcher))
				onOpenResult(null);
			
			function onOpenResult(se:SQLEvent):void {
				localdispatcher.removeEventListener(SQLEvent.RESULT,onOpenResult);
				localdispatcher.removeEventListener(SQLErrorEvent.ERROR,onOpenError);
				localSqlStatement.addEventListener(SQLEvent.RESULT,bgReadingsRetrieved);
				localSqlStatement.addEventListener(SQLErrorEvent.ERROR,bgreadingRetrievalFailed);
				localSqlStatement.sqlConnection = aConn;
				localSqlStatement.text =  "SELECT * from bgreading where timestamp < " + until;
				localSqlStatement.execute();
			}
			
			function bgReadingsRetrieved(se:SQLEvent):void {
				localSqlStatement.removeEventListener(SQLEvent.RESULT,bgReadingsRetrieved);
				localSqlStatement.removeEventListener(SQLErrorEvent.ERROR,bgreadingRetrievalFailed);
				var tempObject:Object = localSqlStatement.getResult().data;
				if (tempObject != null) {
					if (tempObject is Array) {
						for each ( var o:Object in tempObject) {
							var event:DatabaseEvent = new DatabaseEvent(DatabaseEvent.BGREADING_RETRIEVAL_EVENT);
							event.data = new BgReading(
								o.timestamp,
								(o.sensorid as String) == "-" ? null:getSensor(o.sensorid),
								(o.calibrationid as String) == "-" ? null:getCalibration(o.calibrationid),
								o.rawData,
								o.filteredData,
								o.ageAdjustedRawValue,
								o.calibrationFlag == "1" ? true:false,
								o.calculatedValue,
								o.filteredCalculatedValue,
								o.calculatedValeSlopoe,
								o.a,
								o.b,
								o.c,
								o.ra,
								o.rb,
								o.rc,
								o.rawCalculated,
								o.hideSlope == "1" ? true:false,
								(o.noise as String) == "-" ? null:o.noise,
								o.lastmodifiedtimestamp,
								o.bgreadingid);
							instance.dispatchEvent(event);
						}
					}
				} else {
					//no need to dispatch anything, there are no bgreadings
				}
				
				var event:DatabaseEvent = new DatabaseEvent(DatabaseEvent.BGREADING_RETRIEVAL_EVENT);
				event.data = END_OF_RESULT;
				instance.dispatchEvent(event);
			}
			
			function bgreadingRetrievalFailed(see:SQLErrorEvent):void {
				localSqlStatement.removeEventListener(SQLEvent.RESULT,bgReadingsRetrieved);
				localSqlStatement.removeEventListener(SQLErrorEvent.ERROR,bgreadingRetrievalFailed);
				dispatchInformation("failed_to_retrieve_bg_reading", see.error.message + " - " + see.error.details);
				if (debugMode) trace("Database.as : Failed to retrieve bgreadings. Database 0032");
				var errorEvent:DatabaseEvent = new DatabaseEvent(DatabaseEvent.ERROR_EVENT);
				errorEvent.data = "Failed to retrieve bgreadings . Database:0032";
				instance.dispatchEvent(errorEvent);
				
			}
			
			function onOpenError(see:SQLErrorEvent):void {
				localdispatcher.removeEventListener(SQLEvent.RESULT,onOpenResult);
				localdispatcher.removeEventListener(SQLErrorEvent.ERROR,onOpenError);
				dispatchInformation("failed_to_retrieve_bg_reading_error_opening_database", see.error.message + " - " + see.error.details);
				if (debugMode) trace("Database.as : Failed to open the database. Database 0033");
				var event:DatabaseEvent = new DatabaseEvent(DatabaseEvent.ERROR_EVENT);
				instance.dispatchEvent(event);
				
			}
		}
		
		public static function updateCommonSetting(settingId:int,newValue:String, lastModifiedTimeStamp:Number = Number.NaN):void {
			if (newValue == null || newValue == "") newValue = "-";
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var updateRequest:SQLStatement = new SQLStatement();
				updateRequest.sqlConnection = conn;
				var text:String = "UPDATE commonsettings SET ";
				text += "lastmodifiedtimestamp = " + (isNaN(lastModifiedTimeStamp) ? (new Date()).valueOf() : lastModifiedTimeStamp) + ",";
				text += " value = '" + newValue + "'";
				text += " where id  = " + settingId;
				updateRequest.text = text;
				updateRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('error_while_updating_common_setting', error.message + " - " + error.details);
			}
		}
		
		public static function insertCommonSetting(settingId:int, newValue:String, lastModifiedTimeStamp:Number = Number.NaN):void {
			if (newValue == null || newValue == "") newValue = "-";//don't like the null or empty string values, - should be replaced back to null or ""
			try  {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var insertRequest:SQLStatement = new SQLStatement();
				insertRequest.sqlConnection = conn;
				var text:String = "INSERT INTO commonsettings (lastmodifiedtimestamp, value, id) ";
					text += "VALUES (" + (isNaN(lastModifiedTimeStamp) ? (new Date()).valueOf() : lastModifiedTimeStamp) + ", ";
						text += "'" + newValue + "'" + ", ";
						text += settingId + ")"; 
						insertRequest.text = text;
				insertRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('error_while_inserting_common_setting', error.message + " - " + error.details);
			}
		}
		
		public static function updateLocalSetting(settingId:int,newValue:String, lastModifiedTimeStamp:Number = Number.NaN):void {
			if (newValue == null || newValue == "") newValue = "-";
			try {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var updateRequest:SQLStatement = new SQLStatement();
				updateRequest.sqlConnection = conn;
				var text:String =  "UPDATE localsettings SET ";
					text += "lastmodifiedtimestamp = " + (isNaN(lastModifiedTimeStamp) ? (new Date()).valueOf() : lastModifiedTimeStamp) + ",";
						text += " value = '" + newValue + "'";
						text += " where id  = " + settingId;
						updateRequest.text = text;
				updateRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('error_while_updating_local_setting', error.message + " - " + error.details);
			}
		}
		
		public static function insertLocalSetting(settingId:int, newValue:String, lastModifiedTimeStamp:Number = Number.NaN):void {
			if (newValue == null || newValue == "") newValue = "-";//don't like the null or empty string values, - should be replaced back to null or ""
			try  {
				var conn:SQLConnection = new SQLConnection();
				conn.open(dbFile, SQLMode.UPDATE);
				conn.begin();
				var insertRequest:SQLStatement = new SQLStatement();
				insertRequest.sqlConnection = conn;
				insertRequest.text = "INSERT INTO localsettings (lastmodifiedtimestamp, value, id) " +
					"VALUES (" + (isNaN(lastModifiedTimeStamp) ? (new Date()).valueOf() : lastModifiedTimeStamp) + ", " +
					"'" + newValue + "'" + ", "  +
					settingId + ")"; 
				insertRequest.execute();
				conn.commit();
				conn.close();
			} catch (error:SQLError) {
				if (conn.connected) {
					conn.rollback();
					conn.close();
				}
				dispatchInformation('error_while_inserting_local_setting', error.message + " - " + error.details);
			}
		}
		
		/**
		 * if aconn is not open then open aconn to dbFile , in asynchronous mode, in UPDATE mode<br>
		 * returns true if aconn is open<br>
		 * if aConn is closed then connection will be opened asynchronous mode and an event will be dispatched to the dispatcher after opening the connecion<br>
		 * so that means if openSQLConnection returns true then there's no need to wait for the dispatcher event to trigger. <br>
		 */ 
		private static function openSQLConnection(dispatcher:EventDispatcher):Boolean {
			if (aConn != null && aConn.connected) { 
				return true;
			} else {
				aConn = new SQLConnection();
				aConn.addEventListener(SQLEvent.OPEN, onConnOpen);
				aConn.addEventListener(SQLErrorEvent.ERROR, onConnError);
				aConn.openAsync(dbFile, SQLMode.UPDATE);
			}
			
			return false;
			
			function onConnOpen(se:SQLEvent):void {
				if (debugMode) trace("Database.as : SQL Connection successfully opened in method Database.openSQLConnection");
				aConn.removeEventListener(SQLEvent.OPEN, onConnOpen);
				aConn.removeEventListener(SQLErrorEvent.ERROR, onConnError);	
				if (dispatcher != null) {
					dispatcher.dispatchEvent(new DatabaseEvent(DatabaseEvent.RESULT_EVENT));
				}
			}
			
			function onConnError(see:SQLErrorEvent):void {
				if (debugMode) trace("Database.as : SQL Error while attempting to open database in method Database.openSQLConnection");
				aConn.removeEventListener(SQLEvent.OPEN, onConnOpen);
				aConn.removeEventListener(SQLErrorEvent.ERROR, onConnError);
				if (dispatcher != null) {
					dispatcher.dispatchEvent(new DatabaseEvent(DatabaseEvent.ERROR_EVENT));
				}
			}
		}
		
		/**
		 * informationResourceName will look up the text in local/database.properties<br>
		 * additionalInfo will be added after a dash, if not null
		 */
		private static function dispatchInformation(informationResourceName:String, additionalInfo:String = null):void {
			databaseInformationEvent = new DatabaseEvent(DatabaseEvent.DATABASE_INFORMATION_EVENT);
			databaseInformationEvent.data = new Object();
			databaseInformationEvent.data.information = ModelLocator.resourceManagerInstance.getString('database',informationResourceName) + (additionalInfo == null ? "":" - ") + additionalInfo;
			instance.dispatchEvent(databaseInformationEvent);
		}
		
		private static function myTrace(log:String):void {
			Trace.myTrace("xdrip-Calibration.as", log);
		}

	}
}