#!/bin/bash

# Extract URLs and titles from dantan.net.txt and check their status
# Usage: 
#   ./extract.sh parse <input_html> <output_tsv>
#   ./extract.sh check <input_tsv> <output_tsv> <failed_titles_file>
#   ./extract.sh write <input_tsv> <rss_template>

if [ $# -lt 2 ]; then
    echo "Usage:"
    echo "  Parse mode:  $0 parse <input_html_file> <output_tsv_file>"
    echo "  Check mode:  $0 check <input_tsv_file> <output_tsv_file> <failed_titles_file>"
    echo "  Write mode:  $0 write <input_tsv_file> <rss_template_file>"
    echo ""
    echo "Example:"
    echo "  $0 parse dantan.net.txt all_episodes.tsv"
    echo "  $0 check all_episodes.tsv episodes.tsv duds.tsv"
    echo "  $0 write episodes_with_status.tsv dantan_sample.xml"
    exit 1
fi

mode="$1"
input_file="$2"

if [ ! -f "$input_file" ]; then
    echo "Error: File '$input_file' not found"
    exit 1
fi

if [ "$mode" = "parse" ]; then
    output_file="$3"
    
    # Parse HTML file for titles and audio URLs
    # Looks for patterns like: <li>Episode Title...<a href="url">...</a></li>
    
    echo "Parsing $input_file for episode titles and audio URLs..."
    
    # Extract episode entries: find list items with links containing audio files
    # Pattern: <li> containing text and <a> tag with href to audio file
    
    # Use a more sophisticated approach: extract from <li> blocks containing audio links
    perl -ne '
        if (/<li[^>]*>(.*?)<\/li>/s) {
            my $block = $1;
            # Look for title text and audio link in this block
            if ($block =~ /<a\s+href=["'"'"']([^"'"'"']*\.(?:mp3|m4a))[^"'"'"']*["'"'"']/) {
                my $url = $1;
                # Extract title: text before the link or from title attribute
                my $title = $block;
                # Remove HTML tags to get clean text
                $title =~ s/<[^>]+>//g;
                # Get first line or key text as title
                $title =~ s/^\s+|\s+$//g;
                $title =~ s/\s+/ /g;
                # Limit to reasonable length
                $title = substr($title, 0, 100);
                
                # Only process if we have both title and URL
                if ($title && $url) {
                    print "$title\t$url\n";
                }
            }
        }
    ' "$input_file" > "$output_file"
    
    line_count=$(wc -l < "$output_file")
    echo "Extracted $line_count episodes to $output_file (format: title[TAB]url)"
    
elif [ "$mode" = "check" ]; then
    output_file="$3"
    failed_file="$4"
    
    # Check HTTP status for each URL in TSV file and add status column
    # Also outputs titles with failing status codes to a separate file
    
    if [ -z "$failed_file" ]; then
        echo "Error: check mode requires 4 arguments"
        echo "Usage: $0 check <input_tsv_file> <output_tsv_file> <failed_titles_file>"
        exit 1
    fi
    
    echo "Checking HTTP status codes for URLs in $input_file (3 second timeout)..."
    
    > "$output_file"  # Clear output file
    > "$failed_file"  # Clear failed file
    total=0
    success=0
    failed=0
    
    while IFS=$'\t' read -r title url; do
        [ -z "$url" ] && continue
        
        total=$((total + 1))
        
        # Check status code with curl:
        # -I: HEAD request (headers only)
        # -L: follow redirects
        # --max-time 3: 3 second timeout
        # -w "%{http_code}": output only status code
        # -o /dev/null: discard response body
        status=$(curl -s -I -L --max-time 3 -w "%{http_code}" -o /dev/null "$url")
        
        echo "$title	$url	$status" >> "$output_file"
        
        if [ "$status" -eq 200 ] || [ "$status" -eq 301 ] || [ "$status" -eq 302 ]; then
            success=$((success + 1))
            echo "✓ $status - $title"
        else
            failed=$((failed + 1))
            echo "✗ $status - $title"
            echo "$title" >> "$failed_file"
        fi
    done < "$input_file"
    
    echo ""
    echo "Results written to $output_file"
    echo "Failed episodes written to $failed_file"
    echo "Total: $total | Success (2xx/3xx): $success | Failed: $failed"

elif [ "$mode" = "write" ]; then
    rss_template="$3"
    
    if [ -z "$rss_template" ]; then
        echo "Error: write mode requires 2 arguments"
        echo "Usage: $0 write <input_tsv_file> <rss_template_file>"
        exit 1
    fi
    
    if [ ! -f "$rss_template" ]; then
        echo "Error: RSS template file '$rss_template' not found"
        exit 1
    fi
    
    echo "Generating RSS items from $input_file and writing to $rss_template..."
    
    # Create a temporary file to hold the generated items
    temp_items=$(mktemp)
    line_num=0
    
    while IFS=$'\t' read -r title url status; do
        [ -z "$url" ] && continue
        
        line_num=$((line_num + 1))
        
        # Escape special characters for sed replacement (using # as delimiter)
        title_escaped=$(echo "$title" | sed 's/[\/&#]/\\&/g')
        url_escaped=$(echo "$url" | sed 's/[\/&#]/\\&/g')
        
        cat >> "$temp_items" << 'ITEM_EOF'
    <item>
      <title>TITLE_PLACEHOLDER</title>
      <itunes:subtitle>TITLE_PLACEHOLDER</itunes:subtitle>
      <itunes:summary>TITLE_PLACEHOLDER</itunes:summary>
      <description><![CDATA[ <p>TITLE_PLACEHOLDER</p> ]]></description>
      <content:encoded><p>TITLE_PLACEHOLDER</p></content:encoded>
      <enclosure url="URL_PLACEHOLDER" type="audio/mpeg"/>
      <guid isPermaLink="false">line-LINE_PLACEHOLDER</guid>
      <link>https://www.adventuresinodyssey.com/</link>
      <pubDate>1987-01-01T00:00:00Z</pubDate>
    </item>
ITEM_EOF
        
        # Replace placeholders in the last item added
        sed -i '' "s#TITLE_PLACEHOLDER#$title_escaped#g; s#URL_PLACEHOLDER#$url_escaped#g; s#LINE_PLACEHOLDER#$line_num#g" "$temp_items"
    done < "$input_file"
    
    # Now update the RSS template file using sed for insertion
    # Create a temporary file for the output
    temp_rss=$(mktemp)
    
    # Use sed to replace items section
    # Split the operation: everything before BEGIN ITEMS, the marker, items, marker, everything after
    sed -n '1,/<!-- BEGIN ITEMS -->/p' "$rss_template" > "$temp_rss"
    echo "" >> "$temp_rss"
    cat "$temp_items" >> "$temp_rss"
    echo "" >> "$temp_rss"
    sed -n '/<!-- END ITEMS -->/,$p' "$rss_template" >> "$temp_rss"
    
    # Move temp file back to original
    mv "$temp_rss" "$rss_template"
    rm -f "$temp_items"
    
    echo "Updated $rss_template with $line_num items"
    
else
    echo "Error: Unknown mode '$mode'"
    echo "Use 'parse', 'check', or 'write'"
    exit 1
fi
