/*
Custom Post-Processor for GRBL based Openbuilds-style CNC machines
Using Exiting Post Processors as inspiration
For documentation, see GitHub Wiki : https://github.com/Strooom/GRBL-Post-Processor/wiki

22/AUG/2016 - V1 : Kick Off
23/AUG/2016 - V2 : Added Machining Time to Operations overview at file header

*/


description = "Openbuilds Grbl";
vendor = "Openbuilds";
vendorUrl = "http://openbuilds.com";
model = "OX";
description = "Open Hardware Desktop CNC Router";
legal = "Copyright (C) 2012-2016 by Autodesk, Inc.";
certificationLevel = 2;
// minimumRevision = 24000;

extension = "nc";
setCodePage("ascii");
//setEOL(CRLF);	// is default


capabilities = CAPABILITY_MILLING;
tolerance = spatial(0.005, MM);		// 

minimumChordLength = spatial(0.01, MM);
minimumCircularRadius = spatial(0.01, MM);
maximumCircularRadius = spatial(1000, MM);
minimumCircularSweep = toRad(0.01);
maximumCircularSweep = toRad(180);
allowHelicalMoves = true;
allowedCircularPlanes = undefined; // allow any circular motion



// user-defined properties
properties = {
	SpindleOnOffDelay: 0.8	// time (in seconds) the spindle needs to get up to speed or stop
  ///writeMachine: true, // write machine info
  //writeTools: true, // writes the tools info
  //useG28: false, // disable - not needed as we can send G53 to GRBL and this is simpler to uderstand
  //showSequenceNumbers: false, // show sequence numbers
  //sequenceNumberStart: 10, // first sequence number
  //sequenceNumberIncrement: 1, // increment for sequence numbers
  //separateWordsWithSpace: true // specifies that the words should be separated with a white space
};

//var numberOfToolSlots = 9999;
var numberOfToolSlots = 1;

var mapCoolantTable = new Table
	(
	[9, 8],
	{initial:COOLANT_OFF, force:true},
	"Invalid coolant mode"
	);

var gFormat = createFormat({prefix:"G", decimals:0});
var mFormat = createFormat({prefix:"M", decimals:0});

var xyzFormat = createFormat({decimals:(unit == MM ? 3 : 4)});
var feedFormat = createFormat({decimals:0});
var toolFormat = createFormat({decimals:0});
var rpmFormat = createFormat({decimals:0});
var secFormat = createFormat({decimals:1, forceDecimal:true}); // seconds - range 0.001-1000
var taperFormat = createFormat({decimals:1, scale:DEG});

var xOutput = createVariable({prefix:"X"}, xyzFormat);
var yOutput = createVariable({prefix:"Y"}, xyzFormat);
var zOutput = createVariable({prefix:"Z"}, xyzFormat);
var feedOutput = createVariable({prefix:"F"}, feedFormat);
var sOutput = createVariable({prefix:"S", force:true}, rpmFormat);

// circular output
var iOutput = createReferenceVariable({prefix:"I"}, xyzFormat);
var jOutput = createReferenceVariable({prefix:"J"}, xyzFormat);
var kOutput = createReferenceVariable({prefix:"K"}, xyzFormat);

var gMotionModal = createModal({}, gFormat); // modal group 1 // G0-G3, ...
var gPlaneModal = createModal({onchange:function () {gMotionModal.reset();}}, gFormat); // modal group 2 // G17-19
var gAbsIncModal = createModal({}, gFormat); // modal group 3 // G90-91
var gFeedModeModal = createModal({}, gFormat); // modal group 5 // G93-94
var gUnitModal = createModal({}, gFormat); // modal group 6 // G20-21

var WARNING_WORK_OFFSET = 0;

// collected state
var sequenceNumber;
var currentWorkOffset;

function toTitleCase(str)
	{
    return str.replace(/\w\S*/g, function(txt){return txt.charAt(0).toUpperCase() + txt.substr(1).toLowerCase();});
	}

	
function rpm2dial(rpm)
	{
	// translates an RPM for the spindle into a dial value for the Makita and Dewalt routers
	// additionaly, check that spindle rpm is between 10000 and 30000 as this is what our spindle can do
	if (rpm < 10000)
		{
		alert("Warning", rpm + " rpm is below minimum spindle RPM of 10000 rpm");
		return 1;
		}
	else if (rpm < 12000)
		{
		return ((rpm - 10000) / (12000 - 10000)) + 1;
		}
	else if (rpm < 17000)
		{
		return ((rpm - 12000) / (17000 - 12000)) + 2;
		}
	else if (rpm < 22000)
		{
		return ((rpm - 17000) / (22000 - 17000)) + 3;
		}
	else if (rpm < 27000)
		{
		return ((rpm - 22000) / (27000 - 22000)) + 4;
		}
	else if (rpm <= 30000)
		{
		return ((rpm - 27000) / (30000 - 27000)) + 5;
		}
	else
		{
		alert("Warning", rpm + " rpm is above maximum spindle RPM of 30000 rpm");
		return 6;
		}
	}
	
function writeBlock()
	{
	writeWords(arguments);
	}

function formatComment(text)
	{
	return "(" + String(text).replace(/[\(\)]/g, "") + ")";
	}

function writeComment(text)
	{
	writeln(formatComment(text));
	}

function onOpen()
	{
	// Number of checks capturing fatal errors
	// 1. is CAD file in mm, as is our GRBL configuration ?
	if (unit == IN)
		{
		error("*** Imperial units (inches) are not supported - GRBL controller is configured to metric (mm) - Change units in CAD/CAM software to mm ***");
		alert("Error", "*** Imperial units (inches) are not supported - GRBL controller is configured to metric (mm) - Change units in CAD/CAM software to mm ***");
		return;
		}

	// 2. is RadiusCompensation not set incorrectly ?
	onRadiusCompensation();
		
	var myMachine = getMachineConfiguration();
	myMachine.setWidth(600);
	myMachine.setDepth(800);
	myMachine.setHeight(130);
	myMachine.setMaximumSpindlePower(700);
	myMachine.setMaximumSpindleSpeed(30000);
	myMachine.setMilling(true);
	myMachine.setTurning(false);
	myMachine.setToolChanger(false);
	myMachine.setNumberOfTools(1);
	myMachine.setNumberOfWorkOffsets(6);
	myMachine.setVendor("OpenBuilds");
	myMachine.setModel("OX CNC 1000 x 750");
	myMachine.setControl("GRBL V0.9j");

	sequenceNumber = properties.sequenceNumberStart;
	writeln("%");

	var productName = getProduct();
	writeComment("Made in : " + productName);
	writeComment("G-Code optimized for " + myMachine.getVendor() + " " + myMachine.getModel() + " with " + myMachine.getControl() + " controller");
	writeln("");
	
	if (programName)
		{
		writeComment("Program Name : " + programName);
		}
  
	if (programComment)
		{
		writeComment("Program Comments : " + programComment);
		}

	var numberOfSections = getNumberOfSections();
	writeComment(numberOfSections + " Operation" + ((numberOfSections == 1)?"":"s") + " : ");

	for (var i = 0; i < numberOfSections; ++i)
		{
        var section = getSection(i);
        var tool = section.getTool();
		var rpm = section.getMaximumSpindleSpeed();

		if (section.hasParameter("operation-comment"))
			{
			writeComment((i+1) + " : " + section.getParameter("operation-comment"));
			}
		else
			{
			writeComment(i+1);
			}
		
		writeComment("  Tool : " + toTitleCase(getToolTypeName(tool.type)) + " " + tool.numberOfFlutes + " Flutes, Diam = " + xyzFormat.format(tool.diameter) + "mm, Len = " + tool.fluteLength + "mm");
		writeComment("  Spindle : RPM = " + rpm + ", set router dial to " + rpm2dial(rpm));

		var machineTimeInSeconds = section.getCycleTime();
		var machineTimeHours = Math.floor(machineTimeInSeconds / 3600);
		machineTimeInSeconds  = machineTimeInSeconds % 3600;
		var machineTimeMinutes = Math.floor(machineTimeInSeconds / 60);
		var machineTimeSeconds = Math.floor(machineTimeInSeconds % 60);

		if (machineTimeHours > 0)
			{
			writeComment("  Machining time : " + machineTimeHours + " hours " + machineTimeMinutes + " min " + machineTimeSeconds + " sec");
				
			}
		else
			{
			writeComment("  Machining time : " + machineTimeMinutes + " min " + machineTimeSeconds + " sec");
			}
		}
	writeln("");
		
		
	writeBlock(gAbsIncModal.format(90), gFeedModeModal.format(94));
	writeBlock(gPlaneModal.format(17));
    writeBlock(gUnitModal.format(21));
	}

function onComment(message)
	{
	writeComment(message);
	}

function forceXYZ()
	{
	xOutput.reset();
	yOutput.reset();
	zOutput.reset();
	}

function forceAny()
	{
	forceXYZ();
	feedOutput.reset();
	}

function onSection()
	{
	writeln("");
	var nmbrOfSections = getNumberOfSections();
	var curSection = getCurrentSectionId();	
	var comment = "Operation " + (curSection + 1) + " of " + nmbrOfSections;
	if (hasParameter("operation-comment"))
		{
		comment = comment + " : " + getParameter("operation-comment");
		}
	writeComment(comment);

	var section = getSection(curSection);
	var tool = section.getTool();
//	var comment = "Tool : " + toTitleCase(getToolTypeName(tool.type)) + " " + tool.numberOfFlutes + " Flutes, Diam = " + xyzFormat.format(tool.diameter) + "mm, Len = " + tool.fluteLength + "mm";
//	writeComment(comment);
	writeln("");
		
    writeBlock(sOutput.format(tool.spindleRPM), mFormat.format(3));
	if(isFirstSection())
		{
		onDwell(properties.SpindleOnOffDelay);	// Wait some time for spindle to speed up - only on first section, as spindle is not powered down in-between sections
		}
	
//	var retracted = false; // specifies that the tool has been retracted to the safe plane

	var workOffset = currentSection.workOffset;
	if (workOffset == 0)
		{
		workOffset = 1;
		}
  
	writeBlock(gFormat.format(53 + workOffset)); // G54->G59
	currentWorkOffset = workOffset;

	forceXYZ();

    var remaining = currentSection.workPlane;
    if (!isSameDirection(remaining.forward, new Vector(0, 0, 1))) {
      error(localize("Tool orientation is not supported."));
      return;
    }
    setRotation(remaining);

	forceAny();

	// Rapid move to initial position, first Z, then XY
	var initialPosition = getFramePosition(currentSection.getInitialPosition());
	writeBlock(gMotionModal.format(0), zOutput.format(initialPosition.z));
    writeBlock(gAbsIncModal.format(90), gMotionModal.format(0), xOutput.format(initialPosition.x), yOutput.format(initialPosition.y));
	}

function onDwell(seconds)
	{
	writeBlock(gFormat.format(4), "P" + secFormat.format(seconds));
	}

function onSpindleSpeed(spindleSpeed)
	{
	writeBlock(sOutput.format(spindleSpeed));
	}

var pendingRadiusCompensation = -1;

function onRadiusCompensation()
	{
	var radComp = getRadiusCompensation();
	if (radComp != RADIUS_COMPENSATION_OFF)
		{
		error("*** RadiusCompensation is not supported in GRBL - Change RadiusCompensation in CAD/CAM software to Off/Center/Computer ***");
		return;
		}
	}

function onRapid(_x, _y, _z)
	{
	var x = xOutput.format(_x);
	var y = yOutput.format(_y);
	var z = zOutput.format(_z);
	if (x || y || z)
		{
		writeBlock(gMotionModal.format(0), x, y, z);
		feedOutput.reset();
		}
	}

function onLinear(_x, _y, _z, feed)
	{
	var x = xOutput.format(_x);
	var y = yOutput.format(_y);
	var z = zOutput.format(_z);
	var f = feedOutput.format(feed);

	if (x || y || z)
		{
		writeBlock(gMotionModal.format(1), x, y, z, f);
		}
	else if (f)
		{
		if (getNextRecord().isMotion())
			{
			feedOutput.reset(); // force feed on next line
			}
		else
			{
			writeBlock(gMotionModal.format(1), f);
			}
		}
	}

function onRapid5D(_x, _y, _z, _a, _b, _c)
	{
	error(localize("GRBL ony supports 3 Axis"));
	}

function onLinear5D(_x, _y, _z, _a, _b, _c, feed)
	{
	error(localize("GRBL ony supports 3 Axis"));
	}

function onCircular(clockwise, cx, cy, cz, x, y, z, feed)
	{
	// one of X/Y and I/J are required and likewise

	var start = getCurrentPosition();

	if (isFullCircle())
		{
		if (isHelical())
			{
			linearize(tolerance);
			return;
			}

		switch (getCircularPlane())
			{
			case PLANE_XY:
				writeBlock(gPlaneModal.format(17), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), iOutput.format(cx - start.x, 0), jOutput.format(cy - start.y, 0), feedOutput.format(feed));
				break;
			case PLANE_ZX:
				writeBlock(gPlaneModal.format(18), gMotionModal.format(clockwise ? 2 : 3), zOutput.format(z), iOutput.format(cx - start.x, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
				break;
			case PLANE_YZ:
				writeBlock(gPlaneModal.format(19), gMotionModal.format(clockwise ? 2 : 3), yOutput.format(y), jOutput.format(cy - start.y, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
				break;
			default:
				linearize(tolerance);
			}
		}
	else
		{
		switch (getCircularPlane())
			{
			case PLANE_XY:
				writeBlock(gPlaneModal.format(17), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), iOutput.format(cx - start.x, 0), jOutput.format(cy - start.y, 0), feedOutput.format(feed));
				break;
			case PLANE_ZX:
				writeBlock(gPlaneModal.format(18), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), iOutput.format(cx - start.x, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
				break;
			case PLANE_YZ:
				writeBlock(gPlaneModal.format(19), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), jOutput.format(cy - start.y, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
				break;
			default:
				linearize(tolerance);
			}
		}
	}

var mapCommand =
	{
	COMMAND_STOP:0,
	COMMAND_END:2,
	COMMAND_SPINDLE_CLOCKWISE:3,
	COMMAND_SPINDLE_COUNTERCLOCKWISE:4,
	COMMAND_STOP_SPINDLE:5,
	COMMAND_COOLANT_ON:8,
	COMMAND_COOLANT_OFF:9
	};

function onCommand(command)
	{
	switch (command)
		{
		case COMMAND_START_SPINDLE:
			onCommand(tool.clockwise ? COMMAND_SPINDLE_CLOCKWISE : COMMAND_SPINDLE_COUNTERCLOCKWISE);
			return;
		case COMMAND_LOCK_MULTI_AXIS:
			return;
		case COMMAND_UNLOCK_MULTI_AXIS:
			return;
		case COMMAND_BREAK_CONTROL:
			return;
		case COMMAND_TOOL_MEASURE:
			return;
		}

	var stringId = getCommandStringId(command);
	var mcode = mapCommand[stringId];
	if (mcode != undefined)
		{
		writeBlock(mFormat.format(mcode));
		}
	else
		{
		onUnsupportedCommand(command);
		}
	}

function onSectionEnd()
	{
	// writeBlock(gPlaneModal.format(17));
	forceAny();
	// writeComment("Section End");
	writeln("");
	}

function onClose()
	{
	writeBlock(gAbsIncModal.format(90), gFormat.format(53), gMotionModal.format(0), "Z" + xyzFormat.format(-3));	// Retract spindle to Machine Z-3
	writeBlock(mFormat.format(5));	// Stop Spindle
	writeBlock(mFormat.format(9));	// Stop Coolant
	onDwell(properties.SpindleOnOffDelay);	// Wait for spindle to stop
	writeBlock(gAbsIncModal.format(90), gFormat.format(53), gMotionModal.format(0), "X" + xyzFormat.format(-10), "Y" + xyzFormat.format(-10));	// Return to home position
	writeBlock(mFormat.format(30)); // Program End
	writeln("%");					// Punch-Tape End
	}
