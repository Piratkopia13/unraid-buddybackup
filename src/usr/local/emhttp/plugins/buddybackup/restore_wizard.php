<?php
    $plugin = "buddybackup";
    $docroot = $docroot ?? $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
    require_once $docroot."/webGui/include/Helpers.php";
    require_once $docroot."/plugins/".$plugin."/common.php";

    if (!$_GET['uid']) {
        die("no uid set");
    }
?>

<!DOCTYPE html>
<html lang="en">
<head>
<title>BuddyBackup - Restore snapshots</title>

<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta http-equiv="Content-Security-Policy" content="block-all-mixed-content">
<meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="same-origin">

<script src="<?autov('/webGui/javascript/dynamix.js')?>"></script>
<script type="text/javascript">
    // Use style from parent
    window.onload = function() {
        if (parent) {
            var oHead = document.getElementsByTagName("head")[0];
            var arrStyleSheets = parent.document.getElementsByTagName("style");
            for (var i = 0; i < arrStyleSheets.length; i++)
                oHead.appendChild(arrStyleSheets[i].cloneNode(true));

            var arrStyleSheets = parent.document.getElementsByTagName("link");

            for (var i = 0; i < arrStyleSheets.length; i++)
                oHead.appendChild(arrStyleSheets[i].cloneNode(true));
        }
    }
    var api_url = "/plugins/<?=$plugin?>/api.php";
    var the_uid = '<?=$_GET['uid']?>';
    var nchan_buddybackup_restore = new NchanSubscriber('/sub/buddybackup-restore',{subscriber:'websocket'});
    nchan_buddybackup_restore.on('message', function(data) {
        if (!$("#buddybackup-restore-wizard").find("#buddybackup-output-log").length) {
            return;
        }
        
        var output_log = $('#buddybackup-output-log');
        output_log.append(data+'\n');
        output_log.animate({scrollTop:output_log.prop("scrollHeight") - output_log.height()}, 200);

        if (data.includes("[[rc.buddybackup finished]]")) {
            $("#buddybackup-restore-btn").html("");
            nchan_buddybackup_restore.stop();
        }
    });
    nchan_buddybackup_restore.start();

    function get_available_snapshots() {
        list = $('#restore-snapshot');
        list.html("<option selected disabled value=''>Fetching snapshots..</option>");
        var cmd = '<?=$rc_name?> get_available_snapshots "'+the_uid+'"';

        $.post('/webGui/include/StartCommand.php', {cmd: cmd, start:2, csrf_token: '<?=$_GET['csrf_token']?>'})
            .done(function(data) {
                list.html("");

                try {
                    json = JSON.parse(data);
                } catch (error) {
                    list.html("<option selected disabled value=''>Failed! "+error+"</option>");
                    console.error("JSON parse error:", error, ". Data: ", data);
                    return;
                }
                if (json.status != "ok") {
                    list.html("<option selected disabled value=''>Failed! "+json.error+"</option>");
                    return;
                }

                $.each(json.data, function(dataset_name, dataset_data) {
                    var group = '<optgroup label="'+dataset_name+'">';
                    if (jQuery.isEmptyObject(dataset_data)) {
                        group += '<option disabled>No snapshots found</option>';
                    } else {
                        $.each(dataset_data, function(snap_name, snap_data) {
                            group += '<option value="'+snap_name+'">'+snap_name+'</option>';
                        })
                    }
                    group += '</optgroup>'; 
                    list.append(group);
                });
            })
            .fail(function(xhr, status, error) {
                list.html("<option selected disabled value=''>Failed! "+error+"</option>");
            });
    }

    var selected_snap = null;
    var selected_snap_dataset = null;
    var mode = null;

    function restore_snapshot(mode) {
        var selected_option = $('#restore-snapshot').find(':selected');
        selected_snap = selected_option.val();
        selected_snap_dataset = selected_option.parent().attr("label");
        selected_mode = mode;

        var wizard = $('#buddybackup-restore-wizard');
        var choose_destination_html = $('#buddybackup-restore-wizard-choose-destination').html();
        wizard.html(choose_destination_html);

        var wizard_new_dataset = $('#buddybackup-restore-wizard-new-dataset');
        var header = "";
        switch (mode) {
            case "selected":
                header = "<h3>Let's restore the single snapshot '"+selected_snap_dataset+"@"+selected_snap+"'</h3>";
                break;
            case "selected_and":
                header = "<h3>Let's restore '"+selected_snap_dataset+"@"+selected_snap+"' and all newer snapshots</h3>";
                break;
            case "all":
                header = "<h3>Let's restore all snapshots from '"+selected_snap_dataset+"'</h3>";
                break;
            default:
                header = "Unknown restore mode selected";
                break;
        }
        wizard.prepend(header);
        wizard_new_dataset.prepend(header);
        
    }
    function restore_selected_snapshot() {
        restore_snapshot('selected');
    }
    function restore_selected_and_newer_snapshot() {
        restore_snapshot('selected_and_newer');
    }
    function restore_all_snapshots() {
        restore_snapshot('all');
    }

    function abort_operation(pid) {
        swal({title:"Abort background operation",text:"This may leave an unknown state",html:true,animation:'none',type:'warning',showCancelButton:true,confirmButtonText:"Proceed",cancelButtonText:"Cancel"},function(){
            $.post('/webGui/include/StartCommand.php', {kill: pid, csrf_token: '<?=$_GET['csrf_token']?>'}, function() {
                var wizard = $('#buddybackup-restore-wizard');
                wizard.append("Operation aborted!");
            });
        });
    }    

    function new_dataset() {
        var new_dataset_html = $('#buddybackup-restore-wizard-new-dataset').html();
        $('#buddybackup-restore-wizard').html(new_dataset_html);
    }
    
    function start_restoring(new_local_dataset) {
        var wizard = $('#buddybackup-restore-wizard');

        if (!selected_mode || !selected_snap || !selected_snap_dataset) {
            wizard.html("Missing required data. Close this dialogue and try again.");
            return;
        }

        var destination_dataset = null;
        if (new_local_dataset) {
            destination_dataset = wizard.find("#dataset-name").val();
        } else {
            destination_dataset = wizard.find("#existing-dataset-name").find(':selected').val();
        }
        if (!destination_dataset) {
            wizard.html("Empty dataset name. Close this dialogue and try again.");
            return;
        }

        wizard.html("");

        var cmd = '<?=$rc_name?> restore_snapshot "'+the_uid+'" "'+selected_mode+'" "'+selected_snap+'" "'+selected_snap_dataset+'" "'+destination_dataset+'"';
        function isNumeric(str) {
            if (typeof str != "string") return false;
            return !isNaN(str) && !isNaN(parseFloat(str));
        }
        $.post('/webGui/include/StartCommand.php', {cmd: cmd+' nchan', start:2, csrf_token: '<?=$_GET['csrf_token']?>'})
            .done(function(pid) {
                if (!isNumeric(pid)) {
                    nchan_buddybackup_restore.stop();
                    wizard.append("Failed to start restore script: "+pid);
                    return;
                }
                wizard.html($('#buddybackup-restore-wizard-in-progress').html());

                wizard.find("#buddybackup-restore-btn").prepend("Running restore script with pid "+pid+"<br>");
                wizard.find("#buddybackup-abort-restore").attr("onclick", "abort_operation("+pid+")");
            })
            .fail(function(xhr, status, error) {
                wizard.append("Failed! Error: "+error);
            });
    }

    $(function() { 
        get_available_snapshots();
        $('#restore-snapshot').not('.lock').each(function() { $(this).on('input change', function() {
            var snap = $(this).find(':selected').val();
            if (!snap || snap.length === 0) {
                $('.buddybackup-restore-selected').prop('disabled', true);
            } else {
                $('.buddybackup-restore-selected').prop('disabled', false);
            }
        })});
    })
</script>
<style>
    #buddybackup-restore-wizard {
        text-align: center;
        margin: 20px;
    }
    #buddybackup-output-log {
        overflow: auto;
        height: 500px;
        width: 90%;
        padding: 20px;
        background-color: rgba(0, 0, 0, 0.1)
    }
    #restore-snapshot {
        width: 50%;
        height: 500px;
        max-width: 100%;
        min-width: fit-content;
        appearance: none;
        -webkit-appearance: none;
        -moz-appearance: none;
        text-indent: 1px;
        text-overflow: '';
    }
    #restore-snapshot optgroup {
        color: #f2f2f2;
        background-color: #1c1b1b;
        padding: 10px 0px;
    }
    #restore-snapshot select option {
        padding: 5px;
    }
</style>
</head>
<body>
    <div id="buddybackup-restore-wizard">
        <input type="button" value="Update snapshots list" onclick="get_available_snapshots()">
        <br>
        <h3>Your backed-up snapshots:</h3>
        <br>
        <select id="restore-snapshot" name="RestoreSnapshot" class="align" size=10>
            <option selected disabled>Fetching snapshots..</option>
        </select>
        <br>
        <input type="button" class="buddybackup-restore-selected" value="Restore selected snapshot" disabled onclick="restore_selected_snapshot()">
        <!-- <input type="button" class="buddybackup-restore-selected" value="Restore selected and all newer snapshots" disabled onclick="restore_selected_and_newer_snapshot()"> -->
        <input type="button" class="buddybackup-restore-selected" value="Restore all snapshots in selected dataset" disabled onclick="restore_all_snapshots()">
    </div>

    <div id="buddybackup-restore-wizard-choose-destination" style="display:none;">
        <h2>Choose which local dataset to restore to</h2>
        <input type="button" value="New dataset" onclick="new_dataset()">
        <h3>or</h3>
        <select id="existing-dataset-name">
            <?=datasets("", false)?>
        </select>
        <input type="button" value="Restore to selected" onclick="start_restoring(false)">
        <br>
        (Needs to have at least one common snapshot with selected dataset to restore)
    </div>

    <div id="buddybackup-restore-wizard-new-dataset" style="display:none;">
        <h2>Choose which local dataset to restore to</h2>
        Name of new dataset:
        <br>
        <input type="text" id="dataset-name">
        <br>
        <input type="button" value="Start restoring" onclick="start_restoring(true)">
    </div>

    <div id="buddybackup-restore-wizard-in-progress" style="display:none;">
        <h2>Running restore..</h2>
        <textarea readonly id='buddybackup-output-log'></textarea>
        <br>
        <span id="buddybackup-restore-btn">
            <button id="buddybackup-abort-restore" onclick="">
                <i class='fa fa-bomb fa-fw'></i> Abort
            </button>
            <br>
            You may close this window. Restore will continue in the background and a notification is sent when it is finished.
            <br>
        </span>
    </div>
</body>
</html>