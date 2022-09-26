#!/bin/bash

DRY_RUN=0

DESIRED_SECURITY_PROTOCOL="TLSv1.2_2021"
DESIRED_VIEWER_PROTOCOL_POLICY="redirect-to-https"

DISTRO_ALIAS_ENDS_WITH=".dev.example.com.br"

DATE=$(date +%FT%Z%T)
OUTPUT_PATH="outputs/$DATE"
OUTPUT_FILE="$OUTPUT_PATH/$DATE.out"

cloudfront_distros=$(aws cloudfront list-distributions --query \
    "DistributionList.Items[].{id: Id, aliases: Aliases.Items}[?ends_with(aliases[0] || 'a', '$DISTRO_ALIAS_ENDS_WITH')].id" | \
    jq -r '.[]' \
)

mkdir -p $OUTPUT_PATH
for id in $cloudfront_distros; do
    distro_config_path="$OUTPUT_PATH/$id";
    mkdir -p $distro_config_path;
    distro_config_file="$distro_config_path/$DATE.json";
    distro_config_updated_file="$distro_config_path/$DATE.updated.json";

    aws cloudfront get-distribution-config --id $id --output json > $distro_config_file;
    etag=$(jq -r '.ETag' $distro_config_file);
    jq '.DistributionConfig' $distro_config_file > $distro_config_updated_file;
    # yq -i '.ETag = "'$etag'"' -o=json $distro_config_updated_file;
    changed=0;
    security_protocol=$(jq -r '.DistributionConfig.ViewerCertificate.MinimumProtocolVersion' $distro_config_file);
    viewer_protocol_policies=$(jq -r '.DistributionConfig | .DefaultCacheBehavior.ViewerProtocolPolicy, .CacheBehaviors.Items[].ViewerProtocolPolicy' $distro_config_file | sed '/'$DESIRED_VIEWER_PROTOCOL_POLICY'/d' | sort -u);
    viewer_protocol_policy=$(echo $viewer_protocol_policies | head -1);

    if [[ $security_protocol != $DESIRED_SECURITY_PROTOCOL ]]; then
        yq -i '
            .ViewerCertificate.MinimumProtocolVersion = "'$DESIRED_SECURITY_PROTOCOL'"
        ' -o=json $distro_config_updated_file;
        changed=1;
        tee -a $OUTPUT_FILE <<< "$id $security_protocol";
    fi

    if [[ $viewer_protocol_policy != "" ]]; then
        yq -i '
            .DefaultCacheBehavior.ViewerProtocolPolicy = "'$DESIRED_VIEWER_PROTOCOL_POLICY'" |
            .CacheBehaviors.Items[].ViewerProtocolPolicy = "'$DESIRED_VIEWER_PROTOCOL_POLICY'"
        ' -o=json $distro_config_updated_file;
        changed=1;
        viewer_protocol_policies=$(echo -n $viewer_protocol_policies | tr '\n' ',');
        tee -a $OUTPUT_FILE <<< "$id $viewer_protocol_policies";
    fi

    if [[ $DRY_RUN -eq 0 && $changed -eq 1 ]]; then
        aws cloudfront update-distribution --id $id --distribution-config file://$distro_config_updated_file --if-match $etag;
    else
        rm -rf $distro_config_path;
    fi
    exit 0;
done