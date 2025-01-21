<?php
    $plugin = "buddybackup";

    if ($_POST["cmd"] == "get_log") {
        echo file_get_contents("/var/log/buddybackup.log");
    }
?>