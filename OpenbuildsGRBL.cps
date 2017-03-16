/*

Custom Post-Processor for GRBL based Openbuilds-style CNC machines
Using Exiting Post Processors as inspiration
For documentation, see GitHub Wiki : https://github.com/Strooom/GRBL-Post-Processor/wiki
This post-Processor should work on GRBL-based machines such as
* Openbuilds - OX, C-Beam
* Inventables - X-Carve
* ShapeOko / Carbide3D
* your spindle is Makita RT0700 or Dewalt 611

22/AUG/2016 - V1 : Kick Off
23/AUG/2016 - V2 : Added Machining Time to Operations overview at file header
24/AUG/2016 - V3 : Added extra user properties - further cleanup of unused variables
07/SEP/2016 - V4 : Added support for INCHES. Added a safe retract at beginning of first section
11/OCT/2016 - V5
30/JAN/2017 - V6 : Modified capabilities to also allow waterjet, laser-cutting..
*/


description = "Openbuilds Grbl";
vendor = "Openbuilds";
vendorUrl = "http://openbuilds.com";
model = "OX";
description = "Open Hardware Desktop CNC Router";
legal = "Copyright (C) 2012-2016 by Autodesk, Inc.";
certificationLevel = 2;

extension = "nc";										// file extension of the gcode file
setCodePage("ascii");									// character set of the gcode file
//setEOL(CRLF);											// end-of-line type : use CRLF for windows

capabilities = CAPABILITY_MILLING | CAPABILITY_JET;		// intended for a CNC, so Milling
tolerance = spatial(0.005, MM);
minimumChordLength = spatial(0.01, MM);
minimumCircularRadius = spatial(0.01, MM);
maximumCircularRadius = spatial(1000, MM);
minimumCircularSweep = toRad(0.01);
maximumCircularSweep = toRad(180);
allowHelicalMoves = true;
allowedCircularPlanes = undefined;

var GRBLunits = MM;										// GRBL controller set to mm (Metric). Allows for a consistency check between GRBL settings and CAM file output
// var GRBLunits = IN;

// user-defined properties : defaults are set, but they can be changed from a dialog box in Fusion when doing a post.
properties =
	{
	spindleOnOffDelay: 0.8,				// time (in seconds) the spindle needs to get up to speed or stop
	spindleTwoDirections : false,		// true : spindle can rotate clockwise and counterclockwise, will send M3 and M4. false : spindle can only go clockwise, will only send M3
	hasCoolant : false,					// true : machine uses the coolant output, M8 M9 will be sent. false : coolant output not connected, so no M8 M9 will be sent
	hasSpeedDial : true,				// true : the spindle is of type Makite RT0700, Dewalt 611 with a Dial to set speeds 1-6. false : other spindle
	wantHoming: false,
	machineHomeZ : -10,					// absolute machine coordinates where the machine will move to at the end of the job - first retracting Z, then moving home X Y
	machineHomeX : -10,
	machineHomeY : -10
	};

// creation of all kinds of G-code formats - controls the amount of decimals used in the generated G-Code
var gFormat = createFormat({prefix:"G", decimals:0});
var mFormat = createFormat({prefix:"M", decimals:0});

var xyzFormat = createFormat({decimals:(unit == MM ? 3 : 4)});
var arcFormat = createFormat({decimals:(unit == MM ? 4 : 5)});    // uses extra digit in arcs
var abcFormat = createFormat({decimals:3, forceDecimal:true, scale:DEG});
var feedFormat = createFormat({decimals:0});
var rpmFormat = createFormat({decimals:0});
var secFormat = createFormat({decimals:1, forceDecimal:true});
var taperFormat = createFormat({decimals:1, scale:DEG});

var xOutput = createVariable({prefix:"X"}, xyzFormat);
var yOutput = createVariable({prefix:"Y"}, xyzFormat);
var zOutput = createVariable({prefix:"Z"}, xyzFormat);
var aOutput = createVariable({prefix:"A"}, abcFormat);
var bOutput = createVariable({prefix:"B"}, abcFormat);
var cOutput = createVariable({prefix:"C"}, abcFormat);
var feedOutput = createVariable({prefix:"F"}, feedFormat);
var sOutput = createVariable({prefix:"S", force:true}, rpmFormat);

// for arcs, use extra digit
var xaOutput = createVariable({prefix:"X"}, arcFormat);
var yaOutput = createVariable({prefix:"Y"}, arcFormat);
var zaOutput = createVariable({prefix:"Z"}, arcFormat);

var iOutput = createReferenceVariable({prefix:"I"}, arcFormat);
var jOutput = createReferenceVariable({prefix:"J"}, arcFormat);
var kOutput = createReferenceVariable({prefix:"K"}, arcFormat);

var gMotionModal = createModal({}, gFormat); 											// modal group 1 // G0-G3, ...
var gPlaneModal = createModal({onchange:function () {gMotionModal.reset();}}, gFormat); // modal group 2 // G17-19
var gAbsIncModal = createModal({}, gFormat); 											// modal group 3 // G90-91
var gFeedModeModal = createModal({}, gFormat); 											// modal group 5 // G93-94
var gUnitModal = createModal({}, gFormat); 												// modal group 6 // G20-21

function toTitleCase(str)
	{
	// function to reformat a string to 'title case'
	return str.replace(/\w\S*/g, function(txt)
		{
		return txt.charAt(0).toUpperCase() + txt.substr(1).toLowerCase();
		});
	}

function rpm2dial(rpm)
	{
	// translates an RPM for the spindle into a dial value, eg for the Makita RT0700 and Dewalt 611 routers
	// additionaly, check that spindle rpm is between minimun and maximum of what our spindle can do

	// array which maps spindle speeds to router dial settings,
	// according to Makita RT0700 Manual : 1=10000, 2=12000, 3=17000, 4=22000, 5=27000, 6=30000
	var speeds = [0, 10000, 12000, 17000, 22000, 27000, 30000];

	if (rpm < speeds[1])
		{
		alert("Warning", rpm + " rpm is below minimum spindle RPM of " + speeds[1] + " rpm");
		return 1;
		}

	if (rpm > speeds[speeds.length - 1])
		{
		alert("Warning", rpm + " rpm is above maximum spindle RPM of " + speeds[speeds.length - 1] + " rpm");
		return (speeds.length - 1);
		}

	var i;
	for (i=1; i < (speeds.length-1); i++)
		{
		if ((rpm >= speeds[i]) && (rpm <= speeds[i+1]))
			{
			return ((rpm - speeds[i]) / (speeds[i+1] - speeds[i])) + i;
			}
		}

	alert("Error", "Error in calculating router speed dial..");
	error("Fatal Error calculating router speed dial");
	return 0;
	}

function writeBlock()
	{
	writeWords(arguments);
	}

function writeComment(text)
	{
	// Remove special characters which could confuse GRBL : $, !, ~, ?, (, )
	// In order to make it simple, I replace everything which is not A-Z, 0-9, space, : , .
	// Finally put everything between () as this is the way GRBL & UGCS expect comments
	writeln("(" + String(text).replace(/[^a-zA-Z\d :=,.]+/g, " ") + ")");
	}

function onOpen()
	{
    var aAxis = createAxis({coordinate:0, table:true, axis:[(properties.makeAAxisOtherWay ? -1 : 1) * -1, 0, 0], cyclic:true, preference:1});
    machineConfiguration = new MachineConfiguration(aAxis);

    setMachineConfiguration(machineConfiguration);
    optimizeMachineAngles2(1); // map tip mode

	// Number of checks capturing fatal errors
	// 1. is CAD file in same units as our GRBL configuration ?
   // swarfer : GRBL obeys G20/21 so we should only need to output the correct code for the numbers we are outputting, I will look at this later
	if (unit != GRBLunits)
		{
		if (GRBLunits == MM)
			{
			alert("Error", "GRBL configured to mm - CAD file sends Inches! - Change units in CAD/CAM software to mm");
			error("Fatal Error : units mismatch between CADfile and GRBL setting");
			}
		else
			{
			alert("Error", "GRBL configured to inches - CAD file sends mm! - Change units in CAD/CAM software to inches");
			error("Fatal Error : units mismatch between CADfile and GRBL setting");
			}
		}

	// 2. is RadiusCompensation not set incorrectly ?
	onRadiusCompensation();

	bOutput.disable();
	cOutput.disable();

	// 3. here you set all the properties of your machine, so they can be used later on
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

	writeln("%");																								// Punch-Tape Begin, commented out as not supported by GRBL

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
	writeComment(numberOfSections + " Operation" + ((numberOfSections == 1)?"":"s") + " :");

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
      if (section.workOffset > 0)
         {
		   writeComment("  Work Coordinate System : G" + (section.workOffset + 53));
         }
		writeComment("  Tool : " + toTitleCase(getToolTypeName(tool.type)) + " " + tool.numberOfFlutes + " Flutes, Diam = " + xyzFormat.format(tool.diameter) + "mm, Len = " + tool.fluteLength + "mm");
		if (properties.hasSpeedDial)
			{
			writeComment("  Spindle : RPM = " + rpm + ", set router dial to " + rpm2dial(rpm));
			}
		else
			{
			writeComment("  Spindle : RPM = " + rpm);
			}
		var machineTimeInSeconds = section.getCycleTime();
		var machineTimeHours = Math.floor(machineTimeInSeconds / 3600);
		machineTimeInSeconds  = machineTimeInSeconds % 3600;
		var machineTimeMinutes = Math.floor(machineTimeInSeconds / 60);
		var machineTimeSeconds = Math.floor(machineTimeInSeconds % 60);
		var machineTimeText = "  Machining time : ";
		if (machineTimeHours > 0)
			{
			machineTimeText = machineTimeText + machineTimeHours + " hours " + machineTimeMinutes + " min ";
			}
		else if (machineTimeMinutes > 0)
			{
			machineTimeText = machineTimeText + machineTimeMinutes + " min ";
			}
		machineTimeText = machineTimeText + machineTimeSeconds + " sec";
		writeComment(machineTimeText);
		}
	writeln("");

	writeBlock(gAbsIncModal.format(90), gFeedModeModal.format(94));
	writeBlock(gPlaneModal.format(17));
	switch (unit)
		{
		case IN:
			writeBlock(gUnitModal.format(20));
			break;
		case MM:
			writeBlock(gUnitModal.format(21));
			break;
		}

	writeln("");
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
	var nmbrOfSections = getNumberOfSections();		// how many operations are there in total
	var sectionId = getCurrentSectionId();			// what is the number of this operation (starts from 0)
	var section = getSection(sectionId);			// what is the section-object for this operation

	// Insert a small comment section to identify the related G-Code in a large multi-operations file
	var comment = "Operation " + (sectionId + 1) + " of " + nmbrOfSections;
	if (hasParameter("operation-comment"))
		{
		comment = comment + " : " + getParameter("operation-comment");
		}
	writeComment(comment);
	writeln("");

	// To be safe (after jogging to whatever position), move the spindle up to a safe home position before going to the initial position
	// At end of a section, spindle is retracted to clearance height, so it is only needed on the first section
	// it is done with G53 - machine coordinates, so I put it in front of anything else
	if(isFirstSection())
		{
		writeBlock(gAbsIncModal.format(90));	// Set to absolute coordinates
		if (isMilling())
			{
			if(properties.wantHoming) writeBlock(gFormat.format(53), gMotionModal.format(0), "Z" + xyzFormat.format(properties.machineHomeZ));	// Retract spindle to Machine Z Home
			}
		}

	// Write the WCS, ie. G54 or higher.. default to WCS1 / G54 if no or invalid WCS in order to prevent using Machine Coordinates G53
	if ((section.workOffset < 1) || (section.workOffset > 6))
		{
		alert("Warning", "Invalid Work Coordinate System. Select WCS 1..6 in CAM software. Selecting default WCS1/G54");
		//section.workOffset = 1;	// If no WCS is set (or out of range), then default to WCS1 / G54 : swarfer: this appears to be readonly
      writeBlock(gFormat.format(54));  // output what we want, G54
		}
   else
      {
	   writeBlock(gFormat.format(53 + section.workOffset));  // use the selected WCS
      }

	var tool = section.getTool();

	// Insert the Spindle start command
	if (tool.clockwise)
		{
		writeBlock(sOutput.format(tool.spindleRPM), mFormat.format(3));
		}
	else if (properties.spindleTwoDirections)
		{
		writeBlock(sOutput.format(tool.spindleRPM), mFormat.format(4));
		}
	else
		{
		alert("Error", "Counter-clockwise Spindle Operation found, but your spindle does not support this");
		error("Fatal Error in Operation " + (sectionId + 1) + ": Counter-clockwise Spindle Operation found, but your spindle does not support this");
		return;
		}

	// Wait some time for spindle to speed up - only on first section, as spindle is not powered down in-between sections
	if(isFirstSection())
		{
		onDwell(properties.spindleOnOffDelay);
		}

	// If the machine has coolant, write M8 or M9
	if (properties.hasCoolant)
		{
		if (tool.coolant)
			{
			writeBlock(mFormat.format(8));
			}
		else
			{
			writeBlock(mFormat.format(9));
			}
		}

	forceXYZ();

	var remaining = currentSection.workPlane;
	if (!isSameDirection(remaining.forward, new Vector(0, 0, 1)))
		{
		alert("Error", "Tool-Rotation detected - GRBL only supports 3 Axis");
		error("Fatal Error in Operation " + (sectionId + 1) + ": Tool-Rotation detected but GRBL only supports 3 Axis");
		}
	setRotation(remaining);

	forceAny();

	// Rapid move to initial position, first XY, then Z
	var initialPosition = getFramePosition(currentSection.getInitialPosition());
	writeBlock(gAbsIncModal.format(90), gMotionModal.format(0), xOutput.format(initialPosition.x), yOutput.format(initialPosition.y));
	writeBlock(gMotionModal.format(0), zOutput.format(initialPosition.z));
	}

function onDwell(seconds)
	{
	writeBlock(gFormat.format(4), "P" + secFormat.format(seconds));
	}

function onSpindleSpeed(spindleSpeed)
	{
	writeBlock(sOutput.format(spindleSpeed));
	}

function onRadiusCompensation()
	{
	var radComp = getRadiusCompensation();
	var sectionId = getCurrentSectionId();
	if (radComp != RADIUS_COMPENSATION_OFF)
		{
		alert("Error", "RadiusCompensation is not supported in GRBL - Change RadiusCompensation in CAD/CAM software to Off/Center/Computer");
		error("Fatal Error in Operation " + (sectionId + 1) + ": RadiusCompensation is found in CAD file but is not supported in GRBL");
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
	var x = xOutput.format(_x);
	var y = yOutput.format(_y);
	var z = zOutput.format(_z);
	var a = aOutput.format(_a);
	var b = bOutput.format(_b);
	var c = cOutput.format(_c);
	if (x || y || z || a || b || c)
		{
		writeBlock(gMotionModal.format(0), x, y, z, a, b, c);
		feedOutput.reset();
		}
	}

function onLinear5D(_x, _y, _z, _a, _b, _c, feed)
	{
	var x = xOutput.format(_x);
	var y = yOutput.format(_y);
	var z = zOutput.format(_z);
	var a = aOutput.format(_a);
	var b = bOutput.format(_b);
	var c = cOutput.format(_c);
	var f = feedOutput.format(feed);

	if (x || y || z || a || b || c)
		{
		writeBlock(gMotionModal.format(1), x, y, z, a, b, c, f);
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

function onCircular(clockwise, cx, cy, cz, x, y, z, feed)
	{
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
				writeBlock(gPlaneModal.format(17), gMotionModal.format(clockwise ? 2 : 3), xaOutput.format(x), iOutput.format(cx - start.x, 0), jOutput.format(cy - start.y, 0), feedOutput.format(feed));
				break;
			case PLANE_ZX:
				writeBlock(gPlaneModal.format(18), gMotionModal.format(clockwise ? 2 : 3), zaOutput.format(z), iOutput.format(cx - start.x, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
				break;
			case PLANE_YZ:
				writeBlock(gPlaneModal.format(19), gMotionModal.format(clockwise ? 2 : 3), yaOutput.format(y), jOutput.format(cy - start.y, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
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
				writeBlock(gPlaneModal.format(17), gMotionModal.format(clockwise ? 2 : 3), xaOutput.format(x), yaOutput.format(y), zaOutput.format(z), iOutput.format(cx - start.x, 0), jOutput.format(cy - start.y, 0), feedOutput.format(feed));
				break;
			case PLANE_ZX:
				writeBlock(gPlaneModal.format(18), gMotionModal.format(clockwise ? 2 : 3), xaOutput.format(x), yaOutput.format(y), zaOutput.format(z), iOutput.format(cx - start.x, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
				break;
			case PLANE_YZ:
				writeBlock(gPlaneModal.format(19), gMotionModal.format(clockwise ? 2 : 3), xaOutput.format(x), yaOutput.format(y), zaOutput.format(z), jOutput.format(cy - start.y, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
				break;
			default:
				linearize(tolerance);
			}
		}
	}

function onSectionEnd()
	{
	// writeBlock(gPlaneModal.format(17));
	forceAny();
	writeln("");
	}

function onClose()
	{
	writeBlock(gAbsIncModal.format(90));	// Set to absolute coordinates for the following moves
	if (isMilling())
		{
		if(properties.wantHoming) writeBlock(gAbsIncModal.format(90), gFormat.format(53), gMotionModal.format(0), "Z" + xyzFormat.format(properties.machineHomeZ));	// Retract spindle to Machine Z Home
		}
	writeBlock(mFormat.format(5));																					// Stop Spindle
	if (properties.hasCoolant)
		{
		writeBlock(mFormat.format(9));																				// Stop Coolant
		}
	onDwell(properties.spindleOnOffDelay);																			// Wait for spindle to stop
	if(properties.wantHoming) writeBlock(gAbsIncModal.format(90), gFormat.format(53), gMotionModal.format(0), "X" + xyzFormat.format(properties.machineHomeX), "Y" + xyzFormat.format(properties.machineHomeY));	// Return to home position

	writeBlock(mFormat.format(30));																					// Program End
	writeln("%");																									// EndOfFile marker
	}



