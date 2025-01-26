<?php
    $plugin = "buddybackup";
    $docroot = $docroot ?? $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
    require_once $docroot."/webGui/include/Helpers.php";
    require_once $docroot."/plugins/".$plugin."/common.php";
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

        var destination_dataset = null;
        if (new_local_dataset) {
            destination_dataset = wizard.find("#dataset-name").val();
        } else {
            destination_dataset = wizard.find("#existing-dataset-name").find(':selected').val();
        }

        if (destination_dataset) {
            wizard.html("");

            var snap = '<?=$_GET['selected_snapshot']?>';
            var source_dataset = '<?=$_GET['selected_snapshot_dataset']?>';
            var mode = '<?=$_GET['mode']?>';
            var cmd = '<?=$rc_name?> restore_snapshot "'+mode+'" "'+snap+'" "'+source_dataset+'" "'+destination_dataset+'"';
            
            $.post('/webGui/include/StartCommand.php', {cmd: cmd+' nchan', start:0, csrf_token: '<?=$_GET['csrf_token']?>'})
                .done(function(pid) {
                    if (pid == 0) {
                        nchan_buddybackup_restore.stop();
                        wizard.append("Failed to start restore script");
                        return;
                    }
                    wizard.html($('#buddybackup-restore-wizard-in-progress').html());

                    wizard.find("#buddybackup-restore-btn").prepend("Running restore script with pid "+pid+"<br>");
                    wizard.find("#buddybackup-abort-restore").attr("onclick", "abort_operation("+pid+")");
                })
                .fail(function(xhr, status, error) {
                    wizard.append("Failed! Error: "+error);
                });
        } else {
            wizard.html("Empty dataset name. Close this dialogue and try again.");
        }
    }

    $(function() { 
        var wizard = $('#buddybackup-restore-wizard');
        var wizard_new_dataset = $('#buddybackup-restore-wizard-new-dataset');
        var snap = '<?=$_GET['selected_snapshot']?>';
        var source_dataset = '<?=$_GET['selected_snapshot_dataset']?>';
        var mode = '<?=$_GET['mode']?>';

        var header = "";
        switch (mode) {
            case "selected":
                header = "<h3>Let's restore the single snapshot '"+source_dataset+"@"+snap+"'</h3>";
                break;
            case "selected_and":
                header = "<h3>Let's restore '"+source_dataset+"@"+snap+"' and all newer snapshots</h3>";
                break;
            case "all":
                header = "<h3>Let's restore all snapshots from '"+source_dataset+"'</h3>";
                break;
            default:
                header = "Unknown restore mode selected";
                break;
        }
        wizard.prepend(header);
        wizard_new_dataset.prepend(header);
    })
</script>
<style>
    #buddybackup-center {
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
</style>
</head>
<body>
    <div id="buddybackup-center">
        <div id="buddybackup-restore-wizard">
            <h2>Choose which local dataset to restore to</h2>
            <input type="button" value="New dataset" onclick="new_dataset()">
            <h3>or</h3>
            <select id="existing-dataset-name">
                <?=datasets("", false)?>
            </select>
            <input type="button" value="Restore to selected" onclick="start_restoring(false)">
            <br>
            (Needs to have at least one common snapshot with Buddy's dataset)
        </div>
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